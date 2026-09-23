"""Loopback-only cache for timetable and homework copied from an open diary tab."""

import html
import json
import os
import re
import secrets
import sys
import tempfile
from datetime import date, datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import quote


PORT = 8084
ORIGIN = "http://family.home"
MAX_BODY = 65536
DATA_FILE = Path(os.environ.get("STATE_DIRECTORY", "/tmp")) / "diary.json"
TOKEN_FILE = DATA_FILE.with_name("import-token")


def load_token():
    TOKEN_FILE.parent.mkdir(parents=True, exist_ok=True)
    try:
        with TOKEN_FILE.open("x", encoding="ascii") as output:
            output.write(secrets.token_urlsafe(32))
        TOKEN_FILE.chmod(0o600)
    except FileExistsError:
        pass
    return TOKEN_FILE.read_text(encoding="ascii")


def validate(payload):
    if not isinstance(payload, dict) or set(payload) != {"days"}:
        raise ValueError("Invalid diary data")
    days = payload["days"]
    if not isinstance(days, list) or not 1 <= len(days) <= 7:
        raise ValueError("Expected 1–7 days")

    result = []
    for day in days:
        if not isinstance(day, dict) or set(day) != {"date", "lessons"}:
            raise ValueError("Invalid day")
        day_text = day["date"]
        if not isinstance(day_text, str) or not re.fullmatch(r"\d{1,2}\.\d{1,2}", day_text):
            raise ValueError("Invalid date")
        day_num, month_num = map(int, day_text.split("."))
        date(2000, month_num, day_num)
        lessons = day["lessons"]
        if not isinstance(lessons, list) or not 1 <= len(lessons) <= 12:
            raise ValueError("Expected 1–12 lessons")

        validated_lessons = []
        for lesson in lessons:
            if not isinstance(lesson, dict) or set(lesson) != {"number", "time", "subject", "homework"}:
                raise ValueError("Invalid lesson")
            number, time, subject, homework = (lesson[key] for key in ("number", "time", "subject", "homework"))
            if not all(isinstance(value, str) for value in (number, time, subject, homework)):
                raise ValueError("Invalid lesson text")
            if number and (not re.fullmatch(r"\d{1,2}", number) or not 1 <= int(number) <= 12):
                raise ValueError("Invalid lesson number")
            if time and not re.fullmatch(r"\d{1,2}:\d{2}\s*[–—-]\s*\d{1,2}:\d{2}", time):
                raise ValueError("Invalid lesson time")
            if not 1 <= len(subject) <= 100 or len(homework) > 1000:
                raise ValueError("Lesson text too long")
            validated_lessons.append({"number": number, "time": time, "subject": subject, "homework": homework})

        result.append({"date": f"{day_num:02}.{month_num:02}", "lessons": validated_lessons})
    return {"savedAt": datetime.now().astimezone().isoformat(), "days": result}


def display_items(data, today=None):
    if not data:
        return [{"name": "Нет данных", "label": "Добавьте закладку для обновления"}]

    today = today or datetime.now().date()
    items = [{"name": "Обновлено", "label": datetime.fromisoformat(data["savedAt"]).strftime("%d.%m %H:%M")}]
    dated_days = []
    for day in data["days"]:
        day_num, month_num = map(int, day["date"].split("."))
        candidates = []
        for year in (today.year - 1, today.year, today.year + 1):
            try:
                candidates.append(date(year, month_num, day_num))
            except ValueError:
                pass
        actual_date = min(candidates, key=lambda candidate: abs((candidate - today).days))
        if 0 <= (actual_date - today).days <= 14:
            dated_days.append((actual_date, day))

    for actual_date, day in sorted(dated_days, key=lambda item: item[0]):
        for lesson in day["lessons"]:
            prefix = f"{actual_date:%d.%m}"
            if lesson["number"]:
                prefix += f" · {lesson['number']}."
            if lesson["time"]:
                prefix += f" {lesson['time']}"
            items.append({"name": f"{prefix} {lesson['subject']}", "label": lesson["homework"] or "Задание не указано"})

    if len(items) == 1:
        items.append({"name": "Расписание закончилось", "label": "Обновите из журнала"})
    return items


def import_page(bookmarklet):
    link = "javascript:" + quote(bookmarklet, safe="")
    return f"""<!doctype html>
<html lang="ru"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Дневник · family.home</title>
<style>
body {{ font: 17px/1.5 system-ui, sans-serif; max-width: 680px; margin: 8vh auto; padding: 0 20px; color: #e5edf8; background: #0b1728; }}
h1 {{ font-size: 1.8rem; }}
a {{ color: #a8d8ff; }}
.bookmark {{ display: inline-block; padding: 12px 18px; border-radius: 10px; background: #17639e; color: white; text-decoration: none; }}
.status {{ padding: 12px 16px; border-radius: 10px; background: #19304a; }}
</style>
<h1>Расписание и задания на family.home</h1>
<p id="status" class="status">Перетащите кнопку в панель закладок Яндекс Браузера.</p>
<p><a class="bookmark" href="{html.escape(link, quote=True)}">Обновить дневник</a></p>
<ol><li>Откройте электронный дневник в Яндекс Браузере и войдите как обычно.</li>
<li>Откройте нужную неделю и нажмите сохранённую закладку «Обновить дневник».</li>
<li>Вернитесь на <a href="/">family.home</a>: плитка покажет уроки и задания.</li></ol>
<p>Сохраняются только даты, уроки и текст заданий. Логин, оценки, файлы и ссылки не копируются.</p>
<script>
if (location.hash.length > 1) {{
  const status = document.getElementById("status");
  const encoded = location.hash.slice(1);
  history.replaceState(null, "", location.pathname);
  try {{
    const data = JSON.parse(decodeURIComponent(encoded));
    fetch("/school-diary/data", {{
      method: "POST",
      headers: {{ "Content-Type": "application/json" }},
      body: JSON.stringify(data),
    }}).then(async (response) => {{
      if (!response.ok) throw new Error(await response.text());
      status.textContent = "Готово: расписание обновлено. Можно вернуться на family.home.";
    }}).catch(() => {{ status.textContent = "Не удалось обновить данные. Проверьте, что открыта неделя с уроками, и повторите."; }});
  }} catch (_) {{ status.textContent = "Не удалось прочитать расписание. Повторите из открытого дневника."; }}
}}
</script></html>""".encode("utf-8")


class Handler(BaseHTTPRequestHandler):
    bookmarklet = ""
    token = ""

    def respond(self, status, body, content_type="text/plain; charset=utf-8"):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/import":
            self.respond(200, import_page(self.bookmarklet), "text/html; charset=utf-8")
        elif self.path == "/data":
            try:
                data = json.loads(DATA_FILE.read_text(encoding="utf-8"))
            except FileNotFoundError:
                data = None
            except (OSError, ValueError):
                self.respond(500, b"Stored diary data is invalid")
                return
            body = json.dumps({"items": display_items(data)}, ensure_ascii=False).encode("utf-8")
            self.respond(200, body, "application/json; charset=utf-8")
        else:
            self.respond(404, b"Not found")

    def do_POST(self):
        if self.path != "/data":
            self.respond(404, b"Not found")
            return
        if self.headers.get("Origin") != ORIGIN or self.headers.get_content_type() != "application/json":
            self.respond(403, b"Forbidden")
            return
        try:
            self.connection.settimeout(10)
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 < length <= MAX_BODY:
                raise ValueError("Invalid size")
            payload = json.loads(self.rfile.read(length))
            if not isinstance(payload, dict) or payload.pop("token", None) != self.token:
                self.respond(403, b"Forbidden")
                return
            data = validate(payload)
            DATA_FILE.parent.mkdir(parents=True, exist_ok=True)
            with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=DATA_FILE.parent, delete=False) as output:
                json.dump(data, output, ensure_ascii=False)
                temporary = output.name
            os.replace(temporary, DATA_FILE)
        except (ValueError, OSError, UnicodeError):
            self.respond(400, b"Invalid diary data")
            return
        self.respond(200, b"OK")

    def log_message(self, format, *args):
        return


if __name__ == "__main__":
    Handler.token = load_token()
    Handler.bookmarklet = Path(sys.argv[1]).read_text(encoding="utf-8").replace("__IMPORT_TOKEN__", Handler.token)
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
