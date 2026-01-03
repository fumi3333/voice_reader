import flet as ft
import pyttsx3
import threading
import os
from pypdf import PdfReader
import openpyxl

# TTSエンジンの初期化 (Grobal instance)
# pyttsx3はスレッドセーフではないことがあるため、慎重に扱う必要がありますが、
# MVPではシンプルな別スレッド実行で対応します。
engine = pyttsx3.init()

class VoiceReaderApp:
    def __init__(self):
        self.is_playing = False
        self.current_text = ""
        self.speech_thread = None
        self.stop_event = threading.Event()
        self.rate = 1.0

    def parse_file(self, path: str):
        """ファイルの拡張子に応じてテキストを抽出する"""
        _, ext = os.path.splitext(path)
        ext = ext.lower()
        
        try:
            if ext == ".txt":
                with open(path, "r", encoding="utf-8") as f:
                    return f.read()
            elif ext == ".pdf":
                reader = PdfReader(path)
                text = ""
                for page in reader.pages:
                    text += page.extract_text() + "\n"
                return text
            elif ext == ".xlsx":
                wb = openpyxl.load_workbook(path)
                text = ""
                for sheet in wb.worksheets:
                    text += f"--- Sheet: {sheet.title} ---\n"
                    for row in sheet.iter_rows(values_only=True):
                        # Noneを除外して文字列結合
                        row_text = " ".join([str(cell) for cell in row if cell is not None])
                        text += row_text + "\n"
                return text
            else:
                return "未対応のファイル形式です。"
        except Exception as e:
            return f"読み込みエラー: {e}"

    def run_speech(self, text, rate_mult):
        """TTS実行用スレッド関数"""
        try:
            # プロパティ設定はループ開始前に行う
            # 標準速度(通常200くらい) * 倍率
            # voiceupにはきはきした声を求めるため、プロパティを確認することも可能だが、
            # まずはデフォルトで速度調整のみ行う。
            default_rate = 200 
            engine.setProperty('rate', default_rate * rate_mult)
            
            # 日本語音声を探して設定（Windowsの場合）
            voices = engine.getProperty('voices')
            for voice in voices:
                if "Japan" in voice.name or "Haruka" in voice.name:
                    engine.setProperty('voice', voice.id)
                    break

            engine.say(text)
            engine.runAndWait()
        except RuntimeError:
            # 既にループが回っている場合などのエラー回避
            pass
        finally:
            self.is_playing = False

    def stop_speech(self):
        """停止処理"""
        if self.is_playing:
            engine.stop()
            self.is_playing = False

def main(page: ft.Page):
    page.title = "Anti-Gravity Voice Reader"
    page.theme_mode = ft.ThemeMode.LIGHT
    page.window_width = 600
    page.window_height = 500

    app_logic = VoiceReaderApp()

    # UI Components
    status_text = ft.Text("ファイルを読み込んでください", color=ft.colors.GREY_700)
    content_preview = ft.Text("（ここに読み込んだテキストの一部が表示されます）", size=12, max_lines=5, overflow=ft.TextOverflow.ELLIPSIS)

    def on_file_picked(e: ft.FilePickerResultEvent):
        if e.files:
            file_path = e.files[0].path
            status_text.value = f"読み込み中: {file_path}"
            page.update()
            
            extracted_text = app_logic.parse_file(file_path)
            app_logic.current_text = extracted_text
            
            # プレビュー表示（最初の500文字）
            content_preview.value = extracted_text[:500] + ("..." if len(extracted_text) > 500 else "")
            status_text.value = "読み込み完了。再生ボタンを押してください。"
            play_button.disabled = False
            page.update()

    file_picker = ft.FilePicker(on_result=on_file_picked)
    page.overlay.append(file_picker)

    def on_play_click(e):
        if not app_logic.current_text:
            return
        
        if app_logic.is_playing:
            # 既に再生中なら何もしない、あるいは再起動？今回はシンプルに無視
            return

        app_logic.is_playing = True
        status_text.value = "再生中..."
        play_button.disabled = True
        stop_button.disabled = False
        page.update()

        # スレッドで再生
        rate_mult = float(speed_dropdown.value)
        app_logic.speech_thread = threading.Thread(
            target=app_logic.run_speech,
            args=(app_logic.current_text, rate_mult),
            daemon=True
        )
        app_logic.speech_thread.start()
        
        # 完了検知は難しいが、UI側では「再生中」表示のままになるのを防ぐため
        # 簡易的に監視するか、あるいは停止ボタンでリセットするか。
        # MVPなので停止ボタンで手動リセットを基本とするが、
        # 実際にはcallbackが欲しいところ。
        # note: pyttsx3のevent loopはblockingなので、スレッド終了＝読み上げ終了。
        monitor_thread = threading.Thread(target=wait_for_speech_end)
        monitor_thread.start()

    def wait_for_speech_end():
        if app_logic.speech_thread:
            app_logic.speech_thread.join()
        
        app_logic.is_playing = False
        status_text.value = "再生終了"
        play_button.disabled = False
        stop_button.disabled = True
        page.update()

    def on_stop_click(e):
        app_logic.stop_speech()
        status_text.value = "停止しました"
        play_button.disabled = False
        stop_button.disabled = True
        page.update()

    def on_speed_change(e):
        app_logic.rate = float(e.control.value)

    # Controls
    pick_file_btn = ft.ElevatedButton(
        "ファイルを選択 (PDF/Excel/Txt)",
        icon=ft.icons.UPLOAD_FILE,
        on_click=lambda _: file_picker.pick_files(
            allowed_extensions=["txt", "pdf", "xlsx"]
        )
    )

    play_button = ft.ElevatedButton(
        "再生", 
        icon=ft.icons.PLAY_ARROW, 
        on_click=on_play_click,
        disabled=True,
        bgcolor=ft.colors.BLUE_100,
        color=ft.colors.BLUE_800
    )

    stop_button = ft.ElevatedButton(
        "停止", 
        icon=ft.icons.STOP, 
        on_click=on_stop_click,
        disabled=True,
        bgcolor=ft.colors.RED_100,
        color=ft.colors.RED_800
    )

    speed_dropdown = ft.Dropdown(
        label="速度",
        width=100,
        options=[
            ft.dropdown.Option("1.0"),
            ft.dropdown.Option("1.2"),
            ft.dropdown.Option("1.5"),
            ft.dropdown.Option("2.0"),
        ],
        value="1.0",
        on_change=on_speed_change
    )

    # Layout
    page.add(
        ft.Column(
            [
                ft.Text("Anti-Gravity Voice Reader", size=24, weight=ft.FontWeight.BOLD),
                ft.Divider(),
                pick_file_btn,
                status_text,
                ft.Container(height=20),
                content_preview,
                ft.Container(height=20),
                ft.Row([play_button, stop_button, speed_dropdown], alignment=ft.MainAxisAlignment.CENTER),
            ],
            alignment=ft.MainAxisAlignment.START,
            horizontal_alignment=ft.CrossAxisAlignment.CENTER,
            spacing=10
        )
    )

ft.app(target=main)
