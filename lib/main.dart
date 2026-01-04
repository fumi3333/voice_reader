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
  String _currentTitle = "新規テキスト"; // Default to New Text
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
    super.dispose();
  }

  // ... (TTS init code remains same) ...

  // ... (History load code remains same) ...

  Future<void> _saveHistory(String title, String content) async {
    if (content.trim().isEmpty) return; // Don't save empty

    final date = DateTime.now().toString().substring(0, 16);
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
          _textController.text = text; // Update controller
        });
        
        // Auto-save on load
        await _saveHistory(_currentTitle, text);
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("ファイル選択エラー: $e")),
      );
    }
  }
  
  // ... (Chunking code remains same) ...

  Future<void> _speak() async {
    final text = _textController.text;
    if (text.isEmpty) return;
    
    // Only split if starting fresh
    if (!_isPlaying) {
        // Update history with latest edits before speaking if it was modified?
        // Ideally we don't spam history. Let's just speak.
        
        _splitTextIntoChunks(text);
        _currentChunkIndex = 0;
        await flutterTts.setLanguage("ja-JP");
        await flutterTts.setSpeechRate(_speechRate);
        _playNextChunk();
    }
  }

  // ... (PlayNextChunk and Stop remain same) ...
  
  void _clearAndSave() {
    if (_textController.text.isNotEmpty) {
      _saveHistory(_currentTitle, _textController.text);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("履歴に保存してクリアしました")),
      );
    }
    setState(() {
      _textController.clear();
      _currentTitle = "新規テキスト";
      _isPlaying = false;
      flutterTts.stop();
    });
  }

  @override
  Widget build(BuildContext context) {
    // Pages
    final List<Widget> pages = [
      // Reader Tab
      Column(
        children: [
          // Header Area
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    "$_currentTitle", 
                    style: const TextStyle(fontWeight: FontWeight.bold, overflow: TextOverflow.ellipsis)
                  )
                ),
                IconButton(
                  onPressed: _clearAndSave,
                  icon: const Icon(Icons.delete_sweep),
                  tooltip: "保存してクリア",
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          // Editable Text Area
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0),
              child: TextField(
                controller: _textController,
                maxLines: null, // Allow multiline
                expands: true,  // Fill available space
                textAlignVertical: TextAlignVertical.top,
                decoration: const InputDecoration(
                  hintText: "ここにテキストを入力・貼り付け、\nまたは右下のボタンからファイルを読み込んでください。",
                  border: InputBorder.none,
                ),
              ),
            ),
          ),
          // Controls Area
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
                 _textController.text = item['content'] ?? ""; // Load to controller
                 _selectedIndex = 0; // Go to reader
               });
            },
          );
        },
      ),
    ];
    // ... (Scaffold remains same) ...

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
