import http.client
import json
import tempfile
import threading
import unittest
from datetime import date
from http.server import ThreadingHTTPServer
from pathlib import Path

import server


SAMPLE = {
    "days": [{
        "date": "25.09",
        "lessons": [{"number": "2", "time": "13:50–14:30", "subject": "Предмет", "homework": "Прочитать текст"}],
    }],
}


class DiaryTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        server.DATA_FILE = Path(self.directory.name) / "diary.json"
        server.Handler.token = "local-test-token"
        server.Handler.bookmarklet = "alert('test')"
        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), server.Handler)
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.httpd.shutdown()
        self.httpd.server_close()
        self.thread.join()
        self.directory.cleanup()

    def request(self, method, path, body=None, headers=None):
        connection = http.client.HTTPConnection("127.0.0.1", self.httpd.server_port)
        connection.request(method, path, body=body, headers=headers or {})
        response = connection.getresponse()
        result = response.status, response.read()
        connection.close()
        return result

    def test_import_and_widget(self):
        status, body = self.request("GET", "/data")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)["items"][0]["name"], "Нет данных")

        payload = {"token": "local-test-token", **SAMPLE}
        headers = {"Origin": server.ORIGIN, "Content-Type": "application/json"}
        status, _ = self.request("POST", "/data", json.dumps(payload).encode(), headers)
        self.assertEqual(status, 200)
        saved = json.loads(server.DATA_FILE.read_text(encoding="utf-8"))
        self.assertNotIn("token", saved)
        items = server.display_items(saved, today=date(2026, 9, 23))
        self.assertIn("Предмет", items[1]["name"])
        self.assertEqual(items[1]["label"], "Прочитать текст")

    def test_rejects_untrusted_and_invalid_import(self):
        payload = json.dumps({"token": "local-test-token", **SAMPLE}).encode()
        headers = {"Origin": "https://example.invalid", "Content-Type": "application/json"}
        self.assertEqual(self.request("POST", "/data", payload, headers)[0], 403)
        headers["Origin"] = server.ORIGIN
        self.assertEqual(self.request("POST", "/data", payload.replace(b"local-test-token", b"wrong-token"), headers)[0], 403)
        bad = {"token": "local-test-token", "days": [{"date": "31.02", "lessons": SAMPLE["days"][0]["lessons"]}]}
        self.assertEqual(self.request("POST", "/data", json.dumps(bad).encode(), headers)[0], 400)
        self.assertFalse(server.DATA_FILE.exists())

    def test_past_week_prompts_to_update(self):
        data = server.validate(SAMPLE)
        items = server.display_items(data, today=date(2026, 10, 1))
        self.assertEqual(items[-1]["name"], "Расписание закончилось")


if __name__ == "__main__":
    unittest.main()
