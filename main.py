import flet as ft
import pyttsx3
import threading
import os
import sqlite3
import datetime
import logging
import io
import sys
import traceback
from pypdf import PdfReader
import openpyxl

# --- Logging Setup ---
# Capture logs to display in the UI
log_capture_string = io.StringIO()
ch = logging.StreamHandler(log_capture_string)
ch.setLevel(logging.DEBUG)
logger = logging.getLogger(__name__)
logger.setLevel(logging.DEBUG)
logger.addHandler(ch)

# --- Configuration & Constants ---
# DB Logic Removed for PWA compatibility (using client_storage)

# --- TTS Manager (Hybrid) ---
class TTSManager:
    def __init__(self):
        self.engine = None
        try:
            self.engine = pyttsx3.init()
        except Exception as e:
            logger.warning(f"pyttsx3 init failed (Expected on Mobile/Web): {e}")
            
        self.is_playing = False
        self.stop_event = threading.Event()
        self.thread = None

    def speak_desktop(self, text, rate):
        """Standard Pyttsx3 for Desktop (Windows .exe)"""
        if not self.engine:
            logger.error("Desktop TTS engine is unavailable.")
            return

        try:
            self.stop_event.clear()
            # Restore default rate base (approx 200) * rate multiplier
            base_rate = 200
            self.engine.setProperty('rate', int(base_rate * rate))
            
            # Select Japanese voice if possible
            voices = self.engine.getProperty('voices')
            for v in voices:
                if "Japan" in v.name or "Haruka" in v.name:
                    self.engine.setProperty('voice', v.id)
                    break
            
            self.engine.say(text)
            self.engine.runAndWait()
        except Exception as e:
            logger.error(f"Desktop TTS Error: {e}")
        finally:
            self.is_playing = False

    def speak_web(self, page: ft.Page, text, rate):
        """JS SpeechSynthesis for PWA/Mobile"""
        # Note: rate in Web Speech API is 0.1 to 10, default 1.
        # We need to escape text for JS
        safe_text = text.replace('"', '\\"').replace('\n', ' ')
        js_code = f"""
            window.speechSynthesis.cancel();
            var msg = new SpeechSynthesisUtterance("{safe_text}");
            msg.rate = {rate};
            msg.lang = 'ja-JP';
            window.speechSynthesis.speak(msg);
        """
        try:
            page.run_js(js_code)
            self.is_playing = True # In web, we assume playing until replaced
            logger.info(f"Sent JS TTS command (Rate: {rate})")
        except Exception as e:
            logger.error(f"Web TTS Error: {e}")

    def stop_web(self, page: ft.Page):
        try:
            page.run_js("window.speechSynthesis.cancel();")
            self.is_playing = False
        except Exception as e:
            logger.error(f"Web Stop Error: {e}")

    def stop(self):
        if self.engine and self.engine._inLoop:
             self.engine.stop()
        self.is_playing = False


# --- Main Application Logic ---
def main(page: ft.Page):
    logger.info("Application starting...")
    page.title = "Anti-Gravity Voice Reader"
    page.theme_mode = ft.ThemeMode.LIGHT
    # Enable scroll in mobile view
    page.scroll = ft.ScrollMode.HIDDEN 
    
    # Global State
    tts = TTSManager()
    current_content = ft.Ref[str]()
    current_title = ft.Ref[str]()
    
    # --- Persistence Logic (Client Storage) ---
    def get_history():
        # Returns list of dict: [{"title": "t", "content": "c", "date": "d"}]
        try:
            hist = page.client_storage.get("history")
            return hist if hist else []
        except Exception as e:
            logger.error(f"Storage Read Error: {e}")
            return []

    def save_to_history(title, content):
        try:
            hist = get_history()
            # Add new entry
            new_entry = {
                "title": title, 
                "content": content, 
                "date": datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
            }
            # Prepend
            hist.insert(0, new_entry)
            # Limit to 50
            if len(hist) > 50:
                hist = hist[:50]
            page.client_storage.set("history", hist)
            logger.info("Saved item to history.")
        except Exception as e:
            logger.error(f"Storage Save Error: {e}")

    # --- Logic ---
    def parse_file(path):
        logger.info(f"Parsing file: {path}")
        _, ext = os.path.splitext(path)
        ext = ext.lower()
        try:
            if ext == ".txt":
                with open(path, "r", encoding="utf-8") as f: return f.read()
            elif ext == ".pdf":
                reader = PdfReader(path)
                return "\n".join([p.extract_text() for p in reader.pages])
            elif ext == ".xlsx":
                wb = openpyxl.load_workbook(path, data_only=True)
                return "\n".join([" ".join([str(c) for c in r if c]) for s in wb for r in s.iter_rows(values_only=True)])
        except Exception as e: 
             logger.error(f"File Parse Error: {e}")
             return f"Error reading file. Details: {e}"
        return ""

    def load_content(title, content):
        current_title.current = title
        current_content.current = content
        # Update UI
        t_preview.value = content if len(content) < 1000 else content[:1000] + "..."
        t_status.value = f"Loaded: {title}"
        btn_play.disabled = False
        page.update()

    def on_file_picked(e: ft.FilePickerResultEvent):
        try:
            if e.files:
                f = e.files[0]
                logger.info(f"File picked: {f.name}")
                if page.web:
                    logger.info("Web Env detected. Note: File access might vary.")
                
                content = parse_file(f.path)
                save_to_history(f.name, content)
                refresh_history()
                load_content(f.name, content)
        except Exception as e:
            logger.error(f"File Pick Handler Error: {e}")
            page.snack_bar = ft.SnackBar(ft.Text("File Error. Check Debug Tab."), open=True)
            page.update()

    def refresh_history():
        try:
            rows = get_history()
            lv_history.controls.clear()
            for r in rows:
                # r is dict
                lv_history.controls.append(
                    ft.ListTile(
                        title=ft.Text(r["title"], weight=ft.FontWeight.BOLD),
                        subtitle=ft.Text(r["date"], size=12, color=ft.colors.GREY),
                        on_click=lambda e, t=r["title"], c=r["content"]: restore_from_history(t, c)
                    )
                )
            page.update()
        except Exception as e:
            logger.error(f"History Refresh Error: {e}")

    def restore_from_history(title, content):
        load_content(title, content)
        page.navigation_bar.selected_index = 0 # Go to Reader
        show_reader_tab()

    def toggle_play(e):
        try:
            text = current_content.current
            if not text: return
            
            rate = slider_speed.value
            
            if page.web:
                # Web/Mobile Mode
                tts.speak_web(page, text, rate)
                t_status.value = "Playing (Web)..."
            else:
                # Desktop Mode
                if tts.is_playing: return
                tts.is_playing = True
                t_status.value = "Playing (Desktop)..."
                
                # Run in thread
                tts.thread = threading.Thread(
                    target=tts.speak_desktop,
                    args=(text, rate),
                    daemon=True
                )
                tts.thread.start()
                
                # Monitor thread (simple)
                threading.Thread(target=wait_desktop_finish, daemon=True).start()
            
            btn_play.disabled = True
            btn_stop.disabled = False
            page.update()
        except Exception as e:
            logger.error(f"Play Error: {e}")

    def wait_desktop_finish():
        if tts.thread: tts.thread.join()
        t_status.value = "Finished."
        btn_play.disabled = False
        btn_stop.disabled = True
        page.update()

    def stop_playback(e):
        try:
            if page.web:
                tts.stop_web(page)
            else:
                tts.stop()
            
            t_status.value = "Stopped."
            btn_play.disabled = False
            btn_stop.disabled = True
            page.update()
        except Exception as e:
            logger.error(f"Stop Error: {e}")

    # --- UI Components ---
    file_picker = ft.FilePicker(on_result=on_file_picked)
    page.overlay.append(file_picker)

    # Reader Tab Components
    t_status = ft.Text("No content loaded", color=ft.colors.GREY)
    t_preview = ft.Text("", size=14, selectable=True, max_lines=15, overflow=ft.TextOverflow.ELLIPSIS)
    
    slider_speed = ft.Slider(min=0.5, max=2.0, divisions=15, value=1.0, label="{value}x")
    
    btn_pick = ft.FloatingActionButton(icon=ft.icons.UPLOAD_FILE, on_click=lambda _: file_picker.pick_files())
    btn_play = ft.ElevatedButton("Play", icon=ft.icons.PLAY_ARROW, on_click=toggle_play, disabled=True)
    btn_stop = ft.ElevatedButton("Stop", icon=ft.icons.STOP, on_click=stop_playback, disabled=True, color=ft.colors.RED)

    col_reader = ft.Column(
        [
            ft.Text("Reader", size=24, weight=ft.FontWeight.BOLD),
            ft.Container(
                content=ft.Column([
                    ft.Text("Playback Speed", size=12),
                    slider_speed,
                ]),
                padding=10,
                bgcolor=ft.colors.BLUE_50,
                border_radius=8
            ),
            ft.Row([btn_play, btn_stop], alignment=ft.MainAxisAlignment.CENTER),
            ft.Divider(),
            ft.Text("Preview:", weight=ft.FontWeight.BOLD),
            ft.Container(content=t_preview, expand=True, padding=10, border=ft.border.all(1, ft.colors.GREY_300), border_radius=8),
            t_status
        ],
        spacing=15,
        scroll=ft.ScrollMode.AUTO,
        expand=True
    )

    # History Tab Components
    lv_history = ft.ListView(expand=True, spacing=10)
    col_history = ft.Column(
        [
            ft.Text("History", size=24, weight=ft.FontWeight.BOLD),
            ft.Divider(),
            lv_history
        ],
        expand=True
    )

    # Debug Tab Components
    lv_logs = ft.ListView(expand=True, spacing=5, auto_scroll=True)
    
    def refresh_logs():
        log_content = log_capture_string.getvalue()
        lv_logs.controls.clear()
        for line in log_content.split('\\n'):
            if not line: continue
            color = ft.colors.RED if "Error" in line else ft.colors.BLACK
            lv_logs.controls.append(ft.Text(line, size=12, color=color, selectable=True))
        page.update()

    btn_refresh_log = ft.FilledButton("Refresh Logs", on_click=lambda _: refresh_logs())
    col_debug = ft.Column(
        [
            ft.Text("Debug Console", size=24, weight=ft.FontWeight.BOLD, color=ft.colors.RED),
            ft.Text("Checks logs here if app behaves unexpectedly.", size=12),
            btn_refresh_log,
            ft.Divider(),
            ft.Container(
                content=lv_logs, 
                expand=True, 
                bgcolor=ft.colors.GREY_100, 
                padding=10, 
                border_radius=5
            )
        ],
        expand=True
    )

    # Views Control
    def show_reader_tab():
        body_container.content = col_reader
        page.update()
    
    def show_history_tab():
        refresh_history()
        body_container.content = col_history
        page.update()
    
    def show_debug_tab():
        refresh_logs()
        body_container.content = col_debug
        page.update()

    def on_nav_change(e):
        idx = e.control.selected_index
        if idx == 0: show_reader_tab()
        elif idx == 1: show_history_tab()
        elif idx == 2: show_debug_tab()

    body_container = ft.Container(content=col_reader, padding=20, expand=True)

    # Page Layout
    page.add(body_container)
    page.floating_action_button = btn_pick # Floating FAB for file pick
    page.navigation_bar = ft.NavigationBar(
        destinations=[
            ft.NavigationDestination(icon=ft.icons.TEXT_TO_SPEECH, label="Reader"),
            ft.NavigationDestination(icon=ft.icons.HISTORY, label="History"),
            ft.NavigationDestination(icon=ft.icons.BUG_REPORT, label="Debug"),
        ],
        on_change=on_nav_change,
        selected_index=0
    )
    logger.info("UI Ready.")

try:
    ft.app(target=main)
except Exception as e:
    print(f"FATAL ERROR: {e}")
    traceback.print_exc()
