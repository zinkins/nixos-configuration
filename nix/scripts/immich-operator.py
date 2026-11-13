"""Root-only setup and privacy-safe status for the native Immich service."""
import datetime
import getpass
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

BASE = "http://127.0.0.1:2283/api"
MOBILE = "https://immich.zinkin.me"
SHARE = "https://photos.zinkin.me"
STATE = Path("/var/lib/immich-operator")
KEY = STATE / "statistics-key"
CLOUD = Path("/etc/immich-mailru")
GATE = Path("/etc/immich-remote/enabled")
STATUS = Path("/run/immich-health/status.json")
LAST = Path("/var/lib/immich-mailru-backup/last-success")
# Do not send local API credentials through environment-configured proxies.
OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


class SetupError(Exception):
    pass


def api(path, method="GET", body=None, token=None, key=None):
    headers = {"Accept": "application/json"}
    if token:
        headers["Authorization"] = "Bearer " + token
    if key:
        headers["x-api-key"] = key
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    try:
        with OPENER.open(urllib.request.Request(BASE + path, data=data,
                                              headers=headers, method=method), timeout=20) as r:
            raw = r.read()
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        # Response bodies can contain user names or other sensitive data.
        raise SetupError(f"{method} {path.split('?')[0]}: HTTP {e.code}") from None
    except (OSError, ValueError) as e:
        raise SetupError(f"{method} {path.split('?')[0]}: API unavailable") from None


def run(args, timeout=15):
    try:
        return subprocess.run(args, timeout=timeout, stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def ask(prompt):
    return input(prompt + " [y/N] ").strip().lower() in ("y", "yes", "д", "да")


def password(prompt, new=False):
    p = getpass.getpass(prompt)
    if new and (len(p) < 12 or p != getpass.getpass("Повторите пароль: ")):
        raise SetupError("Нужен совпадающий пароль длиной не менее 12 символов.")
    if not p:
        raise SetupError("Пустой пароль.")
    return p


def secret_write(path, value):
    # Never replace a working encryption key or follow an existing symlink.
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as out:
        out.write(value + "\n")


def atomic_status(data):
    STATUS.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(dir=STATUS.parent)
    try:
        with os.fdopen(fd, "w") as out:
            json.dump(data, out, ensure_ascii=False)
        os.chmod(name, 0o644)
        os.replace(name, STATUS)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def fresh_status(last, now):
    if last is None:
        return "Нет успешного бэкапа"
    return "Актуален" if 0 <= now - last <= 36 * 3600 else "Проверьте бэкап"


def http_status(url):
    try:
        with OPENER.open(url, timeout=10) as r:
            return r.status
    except urllib.error.HTTPError as e:
        return e.code
    except (OSError, ValueError):
        return 0


def doctor():
    now = time.time()
    data = dict(checkedAt=int(now), immich="Недоступен", version="—", photos="—",
                videos="—", usage="—", storage="Ошибка", remote="Выключен",
                shares="Недоступен", backup="Не настроен", lastBackup="—",
                fail2ban="Недоступен", archive="Не подключён")
    if run(["mountpoint", "-q", "/myraid1"]):
        data["storage"] = "ZFS подключён"
    try:
        if api("/server/ping")["res"] == "pong":
            data["immich"] = "Работает"
        v = api("/server/version")
        data["version"] = ".".join(str(v[k]) for k in ("major", "minor", "patch"))
        if not api("/server/config")["isInitialized"]:
            data["immich"] = "Требуется настройка"
        if KEY.is_file():
            s = api("/server/statistics", key=KEY.read_text().strip())
            data.update(photos=str(s["photos"]), videos=str(s["videos"]),
                        usage=f'{s["usage"] / 1024**3:.1f} ГиБ')
    except (SetupError, KeyError, OSError, TypeError):
        pass
    if GATE.is_file():
        data["remote"] = ("HTTPS OK (локально)" if http_status(MOBILE + "/api/server/ping") == 200
                          else "Ошибка HTTPS")
    else:
        data["remote"] = ("Ожидает активации" if http_status(MOBILE + "/") == 503
                          else "Выключен / проверьте HTTPS")
    if http_status(SHARE + "/share/healthcheck") == 200:
        data["shares"] = "HTTPS OK (локально)"
    if run(["fail2ban-client", "status", "immich-login"]):
        data["fail2ban"] = "Работает"
    if (CLOUD / "rclone.conf").is_file() and (CLOUD / "restic-password").is_file():
        last = LAST.stat().st_mtime if LAST.is_file() else None
        data["backup"] = fresh_status(last, now)
        if last is not None:
            data["lastBackup"] = datetime.datetime.fromtimestamp(last).strftime("%d.%m %H:%M")
        try:
            active = subprocess.check_output(["systemctl", "show", "-p", "ActiveState", "--value",
                        "restic-backups-immich-mailru.service"], text=True, timeout=5).strip()
        except (OSError, subprocess.SubprocessError):
            active = ""
        if active in ("active", "activating"):
            data["backup"] = "Выполняется"
        elif run(["systemctl", "is-failed", "--quiet", "restic-backups-immich-mailru.service"]):
            data["backup"] = "Ошибка последнего запуска"
    atomic_status(data)
    print(json.dumps(data, ensure_ascii=False, indent=2))


def login(email, p):
    return api("/auth/login", "POST", {"email": email, "password": p})


def setup():
    if not sys.stdin.isatty():
        raise SetupError("Запустите мастер в интерактивном терминале.")
    os.umask(0o077)
    STATE.mkdir(mode=0o700, parents=True, exist_ok=True)
    CLOUD.mkdir(mode=0o700, parents=True, exist_ok=True)
    if not run(["mountpoint", "-q", "/myraid1"]):
        raise SetupError("ZFS не смонтирован.")
    for _ in range(30):
        try:
            if api("/server/ping")["res"] == "pong":
                break
        except SetupError:
            pass
        time.sleep(2)
    else:
        raise SetupError("Immich не отвечает. Проверьте immich-server.service.")
    initialized = api("/server/config")["isInitialized"]
    print("Настройка Immich. Пароли вводятся скрыто, не записываются в Git.")
    admin_email = input("Email отдельного администратора: ").strip().lower()
    p = password("Пароль администратора: ", new=not initialized)
    if not initialized:
        name = input("Имя администратора [Admin]: ").strip() or "Admin"
        api("/auth/admin-sign-up", "POST", dict(email=admin_email, password=p, name=name))
    admin = login(admin_email, p)
    del p
    token = admin["accessToken"]
    owner_token = None
    try:
        if not admin["isAdmin"]:
            raise SetupError("Требуется отдельная учётная запись администратора.")
        existing = api("/admin/users", token=token)
        users = []
        owner_password = None
        for label in ("Первый взрослый (владелец альбома)", "Второй взрослый"):
            email = input(label + ", email: ").strip().lower()
            if not email or email == admin_email or any(x["email"].lower() == email for x in users):
                raise SetupError("Требуются три разных адреса аккаунтов.")
            found = [x for x in existing if x["email"].lower() == email]
            if found:
                user = found[0]
                if user.get("isAdmin") or user.get("deletedAt"):
                    raise SetupError("Выберите действующий обычный аккаунт.")
                print("Аккаунт уже существует; пароль не изменён.")
                if not users:
                    owner_password = password("Пароль владельца альбома: ")
            else:
                name = input("Имя пользователя: ").strip()
                pw = password("Новый пароль пользователя: ", new=True)
                user = api("/admin/users", "POST", dict(email=email, name=name,
                           password=pw, isAdmin=False, shouldChangePassword=False,
                           notify=False), token=token)
                if not users:
                    owner_password = pw
                del pw
            users.append(user)
        owner_token = login(users[0]["email"], owner_password)["accessToken"]
        del owner_password
        title = input("Название общего альбома [Семья]: ").strip() or "Семья"
        matches = api("/albums?" + urllib.parse.urlencode({"name": title, "isOwned": "true"}),
                      token=owner_token)
        if len(matches) > 1:
            raise SetupError("Несколько альбомов с таким именем; выберите уникальное название.")
        member = users[1]["id"]
        if matches:
            album = matches[0]
            roles = {x["user"]["id"]: x["role"] for x in album["albumUsers"]}
            if member not in roles:
                api("/albums/" + album["id"] + "/users", "PUT",
                    {"albumUsers": [{"userId": member, "role": "editor"}]}, token=owner_token)
            elif roles[member] != "editor":
                api("/albums/" + album["id"] + "/user/" + member, "PUT",
                    {"role": "editor"}, token=owner_token)
        else:
            api("/albums", "POST", {"albumName": title,
                "albumUsers": [{"userId": member, "role": "editor"}]}, token=owner_token)
        print("Семейный альбом готов. Публичная ссылка НЕ создана.")
        cfg = api("/system-config", token=token)
        # Public Users controls discoverability of fellow users, not registration.
        # Preserve this setting so the two family accounts can share albums.
        if cfg["server"]["externalDomain"] != SHARE:
            cfg["server"]["externalDomain"] = SHARE
            api("/system-config", "PUT", cfg, token=token)
        # One tightly scoped API key, read by root-only doctor; not Homepage.
        if not KEY.exists():
            candidates = [k for k in api("/api-keys", token=token)
                          if k["name"] == "nixos-immich-statistics"]
            if len(candidates) > 1:
                raise SetupError("Неоднозначный ключ статистики; проверьте API Keys в UI.")
            if candidates:
                k = candidates[0]
                if set(k["permissions"]) != {"server.statistics"}:
                    raise SetupError("Существующий ключ имеет другие права.")
                result = api("/api-keys/" + k["id"] + "/rotate", "POST", token=token)
            else:
                result = api("/api-keys", "POST", {"name": "nixos-immich-statistics",
                             "permissions": ["server.statistics"]}, token=token)
            secret_write(KEY, result["secret"])
        if not (CLOUD / "rclone.conf").exists() and ask("Настроить Mail.ru WebDAV сейчас?"):
            print("Remote: mailru; тип webdav; vendor other; URL https://webdav.cloud.mail.ru; пароль приложения.")
            subprocess.run(["rclone", "config", "--config", str(CLOUD / "rclone.conf")], check=True)
            os.chmod(CLOUD / "rclone.conf", 0o600)
        if (CLOUD / "rclone.conf").exists():
            if not run(["rclone", "--config", str(CLOUD / "rclone.conf"), "lsd", "mailru:"], 60):
                print("Mail.ru не отвечает; проверьте rclone.conf. Бэкап не запускаю.")
            else:
                if not (CLOUD / "restic-password").exists():
                    secret_write(CLOUD / "restic-password", secrets.token_urlsafe(48))
                print("Сохраните /etc/immich-mailru/restic-password вне сервера. Не пересоздавайте ключ!")
                if ask("Ключ сохранён; запустить первый бэкап?"):
                    if not run(["systemctl", "start", "--no-block", "restic-backups-immich-mailru.service"]):
                        print("Не удалось поставить бэкап в очередь.")
        if not GATE.exists() and ask("Разрешить удалённый доступ после проверки HTTPS и Fail2ban?"):
            if http_status(MOBILE + "/") != 503 or not run(["fail2ban-client", "status", "immich-login"]):
                print("HTTPS или Fail2ban не готовы; внешний доступ остаётся выключен.")
            elif not api("/server/config")["isInitialized"]:
                print("Сначала завершите безопасную настройку администратора.")
            else:
                secret_write(GATE, "enabled")
                os.chmod(GATE, 0o644)
                print("Удалённый доступ включён; проверьте с мобильного интернета.")
        print("Настройте приложения на телефонах: " + MOBILE)
        print("Импорт архива и публикация ссылки выполняются отдельно после проверки.")
    finally:
        for t in (owner_token, token):
            if t:
                try:
                    api("/auth/logout", "POST", token=t)
                except SetupError:
                    pass
    doctor()


def main():
    if sys.argv[1:] == ["self-test"]:
        assert fresh_status(None, 1) == "Нет успешного бэкапа"
        assert fresh_status(1, 2) == "Актуален"
        assert fresh_status(1, 200000) == "Проверьте бэкап"
        return
    if os.geteuid() != 0:
        raise SetupError("Используйте sudo.")
    if sys.argv[1:] == ["setup"]:
        setup()
    elif sys.argv[1:] == ["doctor"]:
        doctor()
    else:
        raise SetupError("Используйте immich-setup или immich-doctor.")


if __name__ == "__main__":
    try:
        main()
    except (SetupError, KeyboardInterrupt, EOFError, subprocess.SubprocessError, OSError, KeyError, TypeError) as e:
        print("Настройка или проверка не завершена: " +
              (str(e) if isinstance(e, SetupError) else type(e).__name__), file=sys.stderr)
        sys.exit(1)
