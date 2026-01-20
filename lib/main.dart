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
  bool _isPaused = false;
  double _speechRate = 0.5;
  
  // Chunking & Display State
  List<String> _chunks = [];
  int _currentChunkIndex = 0;
  bool _isReadMode = false; // Toggle between Edit and Read mode
  final ScrollController _scrollController = ScrollController();
  final List<GlobalKey> _chunkKeys = []; // Keys for auto-scrolling
  
  // Content State
  String _currentTitle = "新規テキスト";
  TextEditingController _textController = TextEditingController(); // Controller for editing
  
  // History State
  List<Map<String, String>> _history = [];

  @override
  void initState() {
    super.initState();
    _initTts();
    _loadHistory();
  }
  
  @override
  void dispose() {
    flutterTts.stop();
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _initTts() async {
    flutterTts = FlutterTts();
    
    await flutterTts.setLanguage("ja-JP");
    await flutterTts.setSpeechRate(_speechRate);
    await flutterTts.setVolume(1.0);
    await flutterTts.setPitch(1.0);
    await flutterTts.awaitSpeakCompletion(true);

    flutterTts.setStartHandler(() {
      setState(() {
        _isPlaying = true;
        _isPaused = false;
      });
      _scrollToCurrentChunk();
    });

    flutterTts.setCompletionHandler(() {
      _playNextChunk();
    });

    flutterTts.setErrorHandler((msg) {
      if (msg == "interrupted") return; // Ignore normal stop interactions
      setState(() => _isPlaying = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("読み上げエラー: $msg")),
      );
    });
  }

  // ... (History Loading/Saving remains same) ...

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
    if (content.trim().isEmpty) return;
    final date = DateTime.now().toString().substring(0, 16);
    String savedContent = content;
    if (content.length > 5000) {
      savedContent = content.substring(0, 5000) + "... (省略されました)";
    }
    final entry = {"title": title, "date": date, "content": savedContent};
    setState(() {
      _history.insert(0, entry);
      if (_history.length > 50) _history = _history.sublist(0, 50);
    });
    final prefs = await SharedPreferences.getInstance();
    final List<String> encoded = _history.map((e) => "${e['title']}|||${e['date']}|||${e['content']}").toList();
    await prefs.setStringList('history_encoded_v2', encoded);
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

        if (ext == 'txt') text = await file.readAsString();
        else if (ext == 'pdf') {
          try {
            final PdfDocument document = PdfDocument(inputBytes: file.readAsBytesSync());
            text = PdfTextExtractor(document).extractText();
            document.dispose();
          } catch (e) { text = "PDF読み込みエラー: $e"; }
        } else if (ext == 'xlsx') {
            var bytes = file.readAsBytesSync();
            var excel = Excel.decodeBytes(bytes);
            for (var table in excel.tables.keys) {
              for (var row in excel.tables[table]!.rows) {
                 text += row.map((e) => e?.value ?? "").join(" ") + "\n";
              }
            }
        }
        
        text = text.replaceAll(RegExp(r'\s+'), ' ').trim();
        setState(() {
          _currentTitle = result.files.single.name;
          _textController.text = text;
          _isReadMode = false; // Reset to edit mode on load
        });
        await _saveHistory(_currentTitle, text);
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("ファイル選択エラー: $e")));
    }
  }
  
  void _splitTextIntoChunks(String text) {
     _chunks = [];
     _chunkKeys.clear(); // Clear keys
     
     int chunkSize = 200; 
     RegExp sentenceSplit = RegExp(r'(?<=[。？！\.\?\!\n、,])'); // Include commas
     List<String> sentences = text.split(sentenceSplit);
     
     String currentChunk = "";
     for (String sentence in sentences) {
       if (currentChunk.length + sentence.length < chunkSize) {
         currentChunk += sentence;
       } else {
         if (currentChunk.isNotEmpty) {
             _chunks.add(currentChunk);
             _chunkKeys.add(GlobalKey());
         }
         currentChunk = "";
         if (sentence.length > chunkSize) {
            String tempParams = sentence;
            while (tempParams.length > chunkSize) {
              _chunks.add(tempParams.substring(0, chunkSize));
              _chunkKeys.add(GlobalKey());
              tempParams = tempParams.substring(chunkSize);
            }
            if (tempParams.isNotEmpty) currentChunk = tempParams;
         } else {
            currentChunk = sentence;
         }
       }
     }
     if (currentChunk.isNotEmpty) {
         _chunks.add(currentChunk);
         _chunkKeys.add(GlobalKey());
     }
  }

  Future<void> _speak() async {
    FocusScope.of(context).unfocus(); // キーボードを閉じる
    final text = _textController.text;
    if (text.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("テキストが空です")));
        return;
    }
    
    // 閲覧モードへ自動切り替え
    if (!_isReadMode) {
        setState(() => _isReadMode = true);
        _splitTextIntoChunks(text);
        _currentChunkIndex = 0;
    }

    if (_isPaused) {
        _speakCurrentChunk(); // 再開
    } else if (!_isPlaying) {
        if (_chunks.isEmpty) _splitTextIntoChunks(text);
        _currentChunkIndex = 0; 
        
        await flutterTts.setLanguage("ja-JP");
        await flutterTts.setSpeechRate(_speechRate);
  // 次のチャンクへ進んで再生（完了ハンドラから呼ばれる）
  Future<void> _playNextChunk() async {
    setState(() {
       _currentChunkIndex++;
    });
    if (_currentChunkIndex < _chunks.length) {
      _speakCurrentChunk();
    } else {
      _stop(); // 最後まで読んだら停止
    }
  }

  // 現在のインデックスのチャンクを再生
  Future<void> _speakCurrentChunk() async {
    if (_currentChunkIndex >= 0 && _currentChunkIndex < _chunks.length) {
      setState(() {
           _isPlaying = true;
           _isPaused = false;
      });
      _scrollToCurrentChunk();
      
      await flutterTts.setSpeechRate(_speechRate);
      await flutterTts.speak(_chunks[_currentChunkIndex]);
    }
  }

  Future<void> _stop() async {
    await flutterTts.stop();
    setState(() => _isPlaying = false);
  }  
  Future<void> _pause() async {
      await flutterTts.stop(); // Stop engine
      setState(() {
          _isPlaying = false;
          _isPaused = true; 
      });
  }

  void _skipForward() {
      if (_currentChunkIndex < _chunks.length - 1) {
          flutterTts.stop();
          _currentChunkIndex++;
          _speakCurrentChunk();
      }
  }

  void _skipBack() {
      if (_currentChunkIndex > 0) {
          flutterTts.stop();
          _currentChunkIndex--;
          _speakCurrentChunk();
      }
  }
  
  void _scrollToCurrentChunk() {
     if (_isReadMode && _chunkKeys.isNotEmpty && _currentChunkIndex < _chunkKeys.length) {
         final key = _chunkKeys[_currentChunkIndex];
         if (key.currentContext != null) {
             Scrollable.ensureVisible(
                 key.currentContext!, 
                 alignment: 0.3, // Top 30% of screen
                 duration: const Duration(milliseconds: 300)
             );
         }
     }
  }
  
  // Updating initTTS to use new logic
  // ... (Update in next block) ...

  void _clearAndSave() {
    if (_textController.text.isNotEmpty) {
      _saveHistory(_currentTitle, _textController.text);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("履歴に保存してクリアしました")));
    }
    setState(() {
      _textController.clear();
      _currentTitle = "新規テキスト";
      _isPlaying = false;
      _isPaused = false;
      _isReadMode = false;
      flutterTts.stop();
    });
  }

  String _getEstimatedTime() {
     int charCount = _textController.text.length;
     // Approx 15 chars / sec at 1.0 rate? 
     // Rate 0.5 -> 7.5 chars/sec
     // Let's assume Base (1.0) = 20 chars/sec (Japanese reading is fast)
     // Adjusted = 20 * rate
     if (charCount == 0) return "0分";
     
     double charsPerSec = 20.0 * _speechRate;
     if (charsPerSec <= 0) charsPerSec = 1;
     
     int totalSeconds = charCount ~/ charsPerSec;
     return "${(totalSeconds / 60).ceil()}分";
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("ボイス・リーダー"),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
            // Mode Toggle
            IconButton(
                icon: Icon(_isReadMode ? Icons.edit : Icons.chrome_reader_mode),
                onPressed: () {
                    // Sync text if switching to Read Mode
                    if (!_isReadMode) {
                        _splitTextIntoChunks(_textController.text);
                        // Don't reset index if switching back and forth unless text changed?
                        // For simplicity, keep index if text roughly same length? 
                        // v1: just switch.
                    }
                    setState(() => _isReadMode = !_isReadMode);
                },
                tooltip: _isReadMode ? "編集モードへ" : "閲覧モードへ",
            ),
            IconButton(onPressed: _clearAndSave, icon: const Icon(Icons.delete_sweep)),
        ],
      ),
      body: Column(
        children: [
          // Header
           Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
            child: Row(children: [ Expanded(child: Text("$_currentTitle", style: const TextStyle(fontWeight: FontWeight.bold)))]),
          ),
          const Divider(height: 1),
          
          // Main Content Area (Stack or Switcher)
          Expanded(
              child: _isReadMode 
              ? ListView.separated(
                  controller: _scrollController,
                  padding: const EdgeInsets.all(16),
                  itemCount: _chunks.length,
                  separatorBuilder: (ctx, i) => const SizedBox(height: 8),
                  itemBuilder: (ctx, i) {
                      final isCurrent = (i == _currentChunkIndex);
                      return Container(
                          key: _chunkKeys[i],
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                              color: isCurrent ? Colors.yellow.shade100 : Colors.transparent,
                              borderRadius: BorderRadius.circular(8),
                              border: isCurrent ? Border.all(color: Colors.orange, width: 2) : null,
                          ),
                          child: Text(_chunks[i].trim(), style: TextStyle(
                              fontSize: 16, 
                              fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal
                          )),
                      );
                  }
              )
              : Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16.0),
                  child: TextField(
                    controller: _textController,
                    maxLines: null, expands: true, textAlignVertical: TextAlignVertical.top,
                    decoration: const InputDecoration(hintText: "ここにテキストを入力...", border: InputBorder.none),
                  ),
                )
          ),
          
          // Player Controls
          Container(
             padding: const EdgeInsets.all(12),
             color: Colors.blue.shade50,
             child: Column(
               children: [
                 Row(
                   children: [
                     const Text("速度"),
                     Expanded(
                       child: Slider(
                         value: _speechRate, min: 0.1, max: 2.0, divisions: 19,
                         label: "${_speechRate.toStringAsFixed(1)}倍",
                         onChanged: (val) async {
                             setState(() => _speechRate = val);
                             if (_isPlaying) await flutterTts.setSpeechRate(val);
                         },
                       ),
                     ),
                     Text("${_speechRate.toStringAsFixed(1)}x  (${_getEstimatedTime()})"),
                   ],
                 ),
                 Row(
                   mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                   children: [
                     IconButton(onPressed: _skipBack, icon: const Icon(Icons.replay_10), tooltip: "前の文へ"),
                     FloatingActionButton(
                        onPressed: (_isPlaying && !_isPaused) ? _pause : _speak,
                        child: Icon((_isPlaying && !_isPaused) ? Icons.pause : Icons.play_arrow),
                     ),
                     IconButton(onPressed: _skipForward, icon: const Icon(Icons.forward_10), tooltip: "次の文へ"),
                   ],
                 ),
               ],
             ),
          )
        ],
      ),
      // ... (Bottom Nav and Drawer/FAB if any) ...
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (idx) { 
             // Logic to switch tabs (Reader / History)
             setState(() => _selectedIndex = idx);
        },
        destinations: const [
          NavigationDestination(icon: Icon(Icons.record_voice_over), label: "リーダー"),
          NavigationDestination(icon: Icon(Icons.history), label: "履歴"),
        ],
      ),
      floatingActionButton: _selectedIndex == 0 && !_isReadMode
        ? FloatingActionButton(onPressed: _pickFile, child: const Icon(Icons.upload_file)) 
        : null,
    );
  }
}
