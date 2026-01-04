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
  double _speechRate = 0.5; // FlutterTTS rate is usually 0.0 to 1.0
  
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

  void _initTts() {
    flutterTts = FlutterTts();
    
    flutterTts.setStartHandler(() {
      setState(() => _isPlaying = true);
    });

    flutterTts.setCompletionHandler(() {
      setState(() => _isPlaying = false);
    });

    flutterTts.setErrorHandler((msg) {
      setState(() => _isPlaying = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("TTS Error: $msg")),
      );
    });
  }

  Future<void> _loadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final List<String>? historyList = prefs.getStringList('history_encoded'); // JSON string lists
    // Simplified: We'll use encoded strings "TITLE|DATE|CONTENT" for MVP simplicity
    // or just separate lists. Let's use separate lists for robustness or JSON.
    // For MVP, we won't implement complex JSON serialization manually in this single file easily without code gen.
    // We will use a simple separator approach "|||"
    
    if (historyList != null) {
      setState(() {
        _history = historyList.map((e) {
            final parts = e.split("|||");
            if (parts.length >= 3) {
              return {
                "title": parts[0],
                "date": parts[1],
                "content": parts.sublist(2).join("|||") // Rejoin content if it had separator
              };
            }
            return {"title": "?", "date": "?", "content": ""};
        }).toList();
      });
    }
  }

  Future<void> _saveHistory(String title, String content) async {
    final date = DateTime.now().toString().substring(0, 16);
    final entry = {
      "title": title,
      "date": date,
      "content": content
    };
    
    setState(() {
      _history.insert(0, entry);
      if (_history.length > 50) _history = _history.sublist(0, 50);
    });

    final prefs = await SharedPreferences.getInstance();
    final List<String> encoded = _history.map((e) => "${e['title']}|||${e['date']}|||${e['content']}").toList();
    await prefs.setStringList('history_encoded', encoded);
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
          // PDF Parsing
          try {
            final PdfDocument document = PdfDocument(inputBytes: file.readAsBytesSync());
            text = PdfTextExtractor(document).extractText();
            document.dispose();
          } catch (e) {
            text = "Error reading PDF: $e";
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

        setState(() {
          _currentTitle = result.files.single.name;
          _currentContent = text;
        });
        
        await _saveHistory(_currentTitle, _currentContent);
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Error picking file: $e")),
      );
    }
  }

  Future<void> _speak() async {
    if (_currentContent.isEmpty) return;
    await flutterTts.setLanguage("ja-JP");
    await flutterTts.setSpeechRate(_speechRate);
    await flutterTts.speak(_currentContent);
  }

  Future<void> _stop() async {
    await flutterTts.stop();
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
                  Text("Current File: $_currentTitle", style: const TextStyle(fontWeight: FontWeight.bold)),
                  const Divider(),
                  _currentContent.isEmpty 
                    ? const Text("No content loaded. Tap + to load a file.", style: TextStyle(color: Colors.grey))
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
                     const Text("Speed"),
                     Expanded(
                       child: Slider(
                         value: _speechRate,
                         min: 0.1,
                         max: 1.0,
                         onChanged: (val) => setState(() => _speechRate = val),
                       ),
                     ),
                     Text("${_speechRate.toStringAsFixed(1)}x"),
                   ],
                 ),
                 Row(
                   mainAxisAlignment: MainAxisAlignment.center,
                   children: [
                     ElevatedButton.icon(
                       onPressed: _isPlaying ? null : _speak,
                       icon: const Icon(Icons.play_arrow),
                       label: const Text("Play"),
                     ),
                     const SizedBox(width: 20),
                     ElevatedButton.icon(
                       onPressed: _isPlaying ? _stop : null,
                       icon: const Icon(Icons.stop),
                       label: const Text("Stop"),
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
          NavigationDestination(icon: Icon(Icons.text_to_speech), label: "Reader"),
          NavigationDestination(icon: Icon(Icons.history), label: "History"),
        ],
      ),
    );
  }
}
