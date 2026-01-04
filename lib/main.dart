import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:excel/excel.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart'; 

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Voice Reader',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _selectedIndex = 0;
  
  // TTS State
  late FlutterTts flutterTts;
  bool _isPlaying = false;
  double _speechRate = 0.5;
  
  // Chunking State
  List<String> _chunks = [];
  int _currentChunkIndex = 0;
  
  // Content State
  String _currentTitle = "No content loaded";
  String _currentContent = "";
  
  // History State
  List<Map<String, String>> _history = [];

  @override
  void initState() {
    super.initState();
    _initTts();
    _loadHistory();
  }

  void _initTts() async {
    flutterTts = FlutterTts();
    
    await flutterTts.setLanguage("ja-JP");
    await flutterTts.setSpeechRate(_speechRate);
    await flutterTts.setVolume(1.0);
    await flutterTts.setPitch(1.0);
    await flutterTts.awaitSpeakCompletion(true);

    flutterTts.setStartHandler(() {
      setState(() => _isPlaying = true);
    });

    flutterTts.setCompletionHandler(() {
      // When one chunk finishes, play the next
      _playNextChunk();
    });

    flutterTts.setErrorHandler((msg) {
      setState(() => _isPlaying = false);
      // Ignore routine errors during stop/pause
      if (msg != "interrupted") {
         ScaffoldMessenger.of(context).showSnackBar(
           SnackBar(content: Text("読み上げエラー: $msg")),
         );
      }
    });
  }

  Future<void> _loadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final List<String>? historyList = prefs.getStringList('history_encoded_v2');
    
    if (historyList != null) {
      setState(() {
        _history = historyList.map((e) {
            final parts = e.split("|||");
            if (parts.length >= 2) {
              return {
                "title": parts[0],
                "date": parts[1],
                "content": parts.length > 2 ? parts.sublist(2).join("|||") : ""
              };
            }
            return {"title": "?", "date": "?", "content": ""};
        }).toList();
      });
    }
  }

  Future<void> _saveHistory(String title, String content) async {
    final date = DateTime.now().toString().substring(0, 16);
    // Don't save full content if too long to prevent invalid transaction errors
    // Just save the first 1000 chars as preview if it's huge, 
    // OR we should really rely on file paths.
    // For now, let's truncate content in history to 2000 chars for safety
    String savedContent = content;
    if (content.length > 5000) {
      savedContent = content.substring(0, 5000) + "... (省略されました)";
    }

    final entry = {
      "title": title,
      "date": date,
      "content": savedContent
    };
    
    setState(() {
      _history.insert(0, entry);
      if (_history.length > 50) _history = _history.sublist(0, 50);
    });

    final prefs = await SharedPreferences.getInstance();
    final List<String> encoded = _history.map((e) => "${e['title']}|||${e['date']}|||${e['content']}").toList();
    await prefs.setStringList('history_encoded_v2', encoded); // V2 key to avoid crashes with old huge data
  }

  Future<void> _pickFile() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['txt', 'pdf', 'xlsx'],
      );

      if (result != null) {
        File file = File(result.files.single.path!);
        String text = "";
        String ext = result.files.single.extension?.toLowerCase() ?? "";

        if (ext == 'txt') {
          text = await file.readAsString();
        } else if (ext == 'pdf') {
          try {
            final PdfDocument document = PdfDocument(inputBytes: file.readAsBytesSync());
            text = PdfTextExtractor(document).extractText();
            document.dispose();
          } catch (e) {
            text = "PDF読み込みエラー: $e";
          }
        } else if (ext == 'xlsx') {
            var bytes = file.readAsBytesSync();
            var excel = Excel.decodeBytes(bytes);
            for (var table in excel.tables.keys) {
              for (var row in excel.tables[table]!.rows) {
                 text += row.map((e) => e?.value ?? "").join(" ") + "\n";
              }
            }
        }
        
        // Normalize text
        text = text.replaceAll(RegExp(r'\s+'), ' ').trim();

        setState(() {
          _currentTitle = result.files.single.name;
          _currentContent = text;
        });
        
        await _saveHistory(_currentTitle, _currentContent);
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("ファイル選択エラー: $e")),
      );
    }
  }
  
  void _splitTextIntoChunks(String text) {
     _chunks = [];
     int chunkSize = 200; // Safe size for smooth reading
     
     // Split by simple punctuation first to keep sentences intact
     RegExp sentenceSplit = RegExp(r'(?<=[。？！\.\?\!\n])');
     List<String> sentences = text.split(sentenceSplit);
     
     String currentChunk = "";
     for (String sentence in sentences) {
       if (currentChunk.length + sentence.length < chunkSize) {
         currentChunk += sentence;
       } else {
         if (currentChunk.isNotEmpty) _chunks.add(currentChunk);
         // If a single sentence is huge, just add it (TTS usually handles up to 3-4k, but 200 is safer for UI feedback)
         // But let's split super huge sentences just in case
         if (sentence.length > chunkSize) {
            _chunks.add(sentence); // Let TTS try or implement finer split if needed
         } else {
            currentChunk = sentence;
         }
       }
     }
     if (currentChunk.isNotEmpty) _chunks.add(currentChunk);
  }

  Future<void> _speak() async {
    if (_currentContent.isEmpty) return;
    
    // Only split if starting fresh
    if (!_isPlaying) {
        _splitTextIntoChunks(_currentContent);
        _currentChunkIndex = 0;
        await flutterTts.setLanguage("ja-JP");
        await flutterTts.setSpeechRate(_speechRate);
        _playNextChunk();
    }
  }

  Future<void> _playNextChunk() async {
    if (_currentChunkIndex < _chunks.length) {
      String chunk = _chunks[_currentChunkIndex];
      _currentChunkIndex++;
      await flutterTts.speak(chunk);
    } else {
      setState(() => _isPlaying = false);
    }
  }

  Future<void> _stop() async {
    await flutterTts.stop();
    setState(() => _isPlaying = false);
  }


  @override
  Widget build(BuildContext context) {
    // Pages
    final List<Widget> pages = [
      // Reader Tab
      Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text("ファイル名: $_currentTitle", style: const TextStyle(fontWeight: FontWeight.bold)),
                  const Divider(),
                  _currentContent.isEmpty 
                    ? const Text("読み込むファイルがありません。\n右下の + ボタンを押してファイルを選択してください。", style: TextStyle(color: Colors.grey))
                    : Text(_currentContent),
                ],
              ),
            ),
          ),
          Container(
             padding: const EdgeInsets.all(16),
             color: Colors.blue.shade50,
             child: Column(
               children: [
                 Row(
                   children: [
                     const Text("速度"),
                     Expanded(
                       child: Slider(
                         value: _speechRate,
                         min: 0.1,
                         max: 1.0,
                         onChanged: (val) => setState(() => _speechRate = val),
                       ),
                     ),
                     Text("${_speechRate.toStringAsFixed(1)}倍"),
                   ],
                 ),
                 Row(
                   mainAxisAlignment: MainAxisAlignment.center,
                   children: [
                     ElevatedButton.icon(
                       onPressed: _isPlaying ? null : _speak,
                       icon: const Icon(Icons.play_arrow),
                       label: const Text("再生"),
                     ),
                     const SizedBox(width: 20),
                     ElevatedButton.icon(
                       onPressed: _isPlaying ? _stop : null,
                       icon: const Icon(Icons.stop),
                       label: const Text("停止"),
                       style: ElevatedButton.styleFrom(backgroundColor: Colors.red.shade100),
                     ),
                   ],
                 )
               ],
             ),
          )
        ],
      ),
      // History Tab
      ListView.separated(
        itemCount: _history.length,
        separatorBuilder: (_, __) => const Divider(),
        itemBuilder: (ctx, i) {
          final item = _history[i];
          return ListTile(
            title: Text(item['title'] ?? "", style: const TextStyle(fontWeight: FontWeight.bold)),
            subtitle: Text(item['date'] ?? ""),
            onTap: () {
               setState(() {
                 _currentTitle = item['title'] ?? "";
                 _currentContent = item['content'] ?? "";
                 _selectedIndex = 0; // Go to reader
               });
            },
          );
        },
      ),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text("Voice Reader (Native)"),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: pages[_selectedIndex],
      floatingActionButton: _selectedIndex == 0 
        ? FloatingActionButton(
            onPressed: _pickFile,
            child: const Icon(Icons.upload_file),
          ) 
        : null,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (idx) => setState(() => _selectedIndex = idx),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.record_voice_over), label: "リーダー"),
          NavigationDestination(icon: Icon(Icons.history), label: "履歴"),
        ],
      ),
    );
  }
}
