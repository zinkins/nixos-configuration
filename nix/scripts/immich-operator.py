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


def run(args, timeout=15, env=None):
    try:
        return subprocess.run(args, timeout=timeout, stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL,
                              env=env).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def cloud_environment():
    # This password unlocks rclone.conf, not WebDAV or the Restic repository.
    env = os.environ.copy()
    env.pop("RCLONE_CONFIG_PASS", None)
    env["RCLONE_ASK_PASSWORD"] = "false"
    env["RCLONE_PASSWORD_COMMAND"] = "cat " + str(CLOUD / "rclone-config-password")
    return env


def prepare_cloud():
    conf = CLOUD / "rclone.conf"
    with conf.open("rb") as src:
        encrypted = any(line.startswith(b"RCLONE_ENCRYPT_V") for line in src)
    env = cloud_environment()
    if encrypted and not (CLOUD / "rclone-config-password").exists():
        print("rclone.conf зашифрован. Для ежедневного бэкапа нужен пароль его расшифровки.")
        if not ask("Сохранить его локально в root-only файле rclone-config-password?"):
            print("Пароль не сохранён; автоматический бэкап не настроен.")
            return None
        value = password("Пароль шифрования rclone.conf (не Mail.ru и не Restic): ")
        trial = env.copy()
        trial.pop("RCLONE_PASSWORD_COMMAND", None)
        trial["RCLONE_CONFIG_PASS"] = value
        if not run(["rclone", "--config", str(conf), "listremotes"], env=trial):
            print("Не удалось открыть rclone.conf; проверьте пароль шифрования. Бэкап не запускаю.")
            return None
        secret_write(CLOUD / "rclone-config-password", value)
        del value, trial
    if not run(["rclone", "--config", str(conf), "listremotes"], env=env):
        print("Не удалось открыть rclone.conf; проверьте файл и пароль шифрования. Бэкап не запускаю.")
        return None
    return env


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


def inventory():
    """Read only identity/album metadata from the local PostgreSQL instance.
    Never fetch password hashes, sessions, API keys or asset information.
    All changes still use supported Immich APIs.
    """
    sql = """
    SELECT json_build_object(
      'users', COALESCE((SELECT json_agg(json_build_object(
        'id', id, 'email', email, 'name', name, 'isAdmin', "isAdmin"))
        FROM public."user" WHERE "deletedAt" IS NULL AND status = 'active'), '[]'::json),
      'albums', COALESCE((SELECT json_agg(json_build_object(
        'id', a.id, 'name', a."albumName", 'members',
        COALESCE((SELECT json_object_agg(m."userId", m.role)
          FROM public.album_user m WHERE m."albumId" = a.id), '{}'::json)))
        FROM public.album a WHERE a."deletedAt" IS NULL), '[]'::json)
    );
    """
    try:
        raw = subprocess.check_output(
            ["runuser", "-u", "postgres", "--", "psql", "-X", "-qAt",
             "-v", "ON_ERROR_STOP=1", "--dbname", os.environ["IMMICH_OPERATOR_DB"],
             "-c", "BEGIN READ ONLY; " + sql + " COMMIT;"],
            stderr=subprocess.DEVNULL, timeout=20, text=True,
            env={**os.environ, "PGOPTIONS": "-c default_transaction_read_only=on"},
        )
        return json.loads(raw)
    except (OSError, subprocess.SubprocessError, ValueError, KeyError):
        raise SetupError("Не удалось проверить локальную базу Immich. "
                         "Настройка аккаунтов остановлена; проверьте PostgreSQL.") from None


def read_selection():
    try:
        return json.loads((STATE / "family-selection.json").read_text())
    except FileNotFoundError:
        return {}
    except (OSError, ValueError):
        raise SetupError("Не удалось прочитать family-selection.json; проверьте файл.")


def save_selection(selection):
    path = STATE / "family-selection.json"
    fd, name = tempfile.mkstemp(dir=STATE)
    try:
        with os.fdopen(fd, "w") as out:
            json.dump(selection, out)
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def select_existing(items, saved, label):
    """Reuse stored UUID, or infer a unique existing choice; ask only on ambiguity."""
    if saved:
        match = next((x for x in items if x["id"] == saved), None)
        if match:
            return match
    if len(items) == 1:
        return items[0]
    if not items:
        return None
    print(label + ":")
    for i, item in enumerate(items, 1):
        print(f"  {i}. {item['name']}" + (f" ({item['email']})" if "email" in item else ""))
    choice = input("Номер существующей записи: ").strip()
    if not choice.isdigit() or not 1 <= int(choice) <= len(items):
        raise SetupError("Неверный выбор; записи не изменены.")
    return items[int(choice) - 1]


def family_candidates(data):
    """Only infer a family from an existing owner/editor pair of ordinary users."""
    ordinary = {u["id"]: u for u in data["users"] if not u["isAdmin"]}
    result = []
    for a in data["albums"]:
        owners = [uid for uid, role in a["members"].items() if role == "owner" and uid in ordinary]
        editors = [uid for uid, role in a["members"].items() if role == "editor" and uid in ordinary]
        if len(owners) == 1:
            for editor in editors:
                result.append(dict(id=a["id"], name=a["name"], owner=owners[0], editor=editor))
    return result


def existing_family(data, saved):
    candidates = family_candidates(data)
    # Never silently substitute a different family when a remembered one is missing.
    if saved.get("album"):
        return next((c for c in candidates if c["id"] == saved["album"]
                     and c["owner"] == saved.get("owner") and c["editor"] == saved.get("editor")), None)
    # Migration from the old wizard: infer only when there are exactly two
    # ordinary accounts and an unambiguous qualifying album.
    ordinary = [u for u in data["users"] if not u["isAdmin"]]
    if len(ordinary) == 2:
        if len(candidates) == 1:
            return candidates[0]
        if len(candidates) > 1:
            return select_existing(candidates, None, "Выберите существующий семейный альбом")
    return None


def stats_key_valid():
    if not KEY.is_file():
        return False
    try:
        api("/server/statistics", key=KEY.read_text().strip())
        return True
    except (SetupError, OSError):
        return False


def configure_accounts(initialized):
    saved = read_selection()
    data = inventory()
    admins = [u for u in data["users"] if u["isAdmin"]]
    family = existing_family(data, saved)
    config_ready = api("/server/config")["externalDomain"] == SHARE
    statistics_ready = stats_key_valid()
    # Fully configured existing installation (including the pre-state-file
    # version): no login, no credentials, and no mutation of users/albums.
    if initialized and admins and family and config_ready and statistics_ready:
        selection = {"album": family["id"], "owner": family["owner"], "editor": family["editor"]}
        if len(admins) == 1:
            selection["admin"] = admins[0]["id"]
        elif any(a["id"] == saved.get("admin") for a in admins):
            selection["admin"] = saved["admin"]
        save_selection(selection)
        print("Администратор, два аккаунта, общий альбом и настройки уже готовы. Пропускаю.")
        return

    admin_token = None
    owner_token = None
    try:
        admin = select_existing(admins, saved.get("admin"), "Администратор") if admins else None

        def ensure_admin():
            nonlocal admin, admin_token
            if admin_token:
                return admin_token
            if admin is None:
                if initialized:
                    raise SetupError("Не найден действующий администратор.")
                email = input("Email отдельного администратора: ").strip().lower()
                pw = password("Новый пароль администратора: ", new=True)
                name = input("Имя администратора [Admin]: ").strip() or "Admin"
                api("/auth/admin-sign-up", "POST", dict(email=email, password=pw, name=name))
            else:
                email = admin["email"]
                pw = password("Пароль администратора (нужен для незавершённой настройки): ")
            response = login(email, pw)
            del pw
            admin_token = response["accessToken"]
            if not response["isAdmin"]:
                raise SetupError("Требуется учётная запись администратора.")
            admin = {"id": response["userId"], "email": email, "isAdmin": True}
            saved["admin"] = admin["id"]
            save_selection(saved)
            return admin_token

        if not admins:
            ensure_admin()
        else:
            print("Администратор уже существует.")

        if not family:
            ordinary = [u for u in data["users"] if not u["isAdmin"]]
            users = []
            owner_password = None
            for role, label in (("owner", "Владелец семейного альбома"), ("editor", "Второй взрослый")):
                remaining = [u for u in ordinary if u["id"] not in {x["id"] for x in users}]
                user = select_existing(remaining, saved.get(role), label)
                if user:
                    print(label + ": существующий аккаунт найден.")
                else:
                    token = ensure_admin()
                    email = input(label + ", email: ").strip().lower()
                    name = input("Имя пользователя: ").strip()
                    pw = password("Новый пароль пользователя: ", new=True)
                    user = api("/admin/users", "POST", dict(email=email, name=name,
                               password=pw, isAdmin=False, shouldChangePassword=False,
                               notify=False), token=token)
                    if role == "owner":
                        owner_password = pw
                    del pw
                users.append(user)
                saved[role] = user["id"]
                save_selection(saved)
            owner, editor = users
            # When roles were lost or an album is missing, do not guess
            # which album to modify or grant access without the owner's consent.
            title = input("Название общего альбома [Семья]: ").strip() or "Семья"
            existing = [a for a in data["albums"] if a["name"] == title
                        and a["members"].get(owner["id"]) == "owner"]
            if len(existing) > 1:
                raise SetupError("Несколько альбомов с таким названием; выберите уникальное.")
            if not ask("Создать/настроить этот альбом и предоставить второму аккаунту права Editor?"):
                raise SetupError("Настройка альбома отложена.")
            if owner_password is None:
                owner_password = password("Пароль владельца (нужен только для настройки альбома): ")
            owner_token = login(owner["email"], owner_password)["accessToken"]
            del owner_password
            member = editor["id"]
            if existing:
                album = existing[0]
                role = album["members"].get(member)
                if role is None:
                    api("/albums/" + album["id"] + "/users", "PUT",
                        {"albumUsers": [{"userId": member, "role": "editor"}]}, token=owner_token)
                elif role != "editor":
                    api("/albums/" + album["id"] + "/user/" + member, "PUT",
                        {"role": "editor"}, token=owner_token)
            else:
                album = api("/albums", "POST", {"albumName": title,
                            "albumUsers": [{"userId": member, "role": "editor"}]}, token=owner_token)
            saved.update(album=album["id"], owner=owner["id"], editor=editor["id"])
            save_selection(saved)
        else:
            saved.update(album=family["id"], owner=family["owner"], editor=family["editor"])
            save_selection(saved)
            print("Оба обычных аккаунта и права общего альбома уже настроены.")
        print("Публичная ссылка не изменена.")

        if not config_ready:
            token = ensure_admin()
            cfg = api("/system-config", token=token)
            cfg["server"]["externalDomain"] = SHARE
            api("/system-config", "PUT", cfg, token=token)
        if not statistics_ready:
            token = ensure_admin()
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
            if KEY.exists():
                # Replace only a key which has been checked and rejected.
                KEY.unlink()
            secret_write(KEY, result["secret"])
    finally:
        for t in (owner_token, admin_token):
            if t:
                try:
                    api("/auth/logout", "POST", token=t)
                except SetupError:
                    pass


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
    configure_accounts(initialized)
    if not (CLOUD / "rclone.conf").exists() and ask("Настроить Mail.ru WebDAV сейчас?"):
        print("Remote: mailru; тип webdav; vendor other; URL https://webdav.cloud.mail.ru; пароль приложения.")
        subprocess.run(["rclone", "config", "--config", str(CLOUD / "rclone.conf")], check=True)
        os.chmod(CLOUD / "rclone.conf", 0o600)
    if (CLOUD / "rclone.conf").exists():
        cloud_env = prepare_cloud()
        if cloud_env is None:
            pass
        elif not run(["rclone", "--config", str(CLOUD / "rclone.conf"), "lsd", "mailru:"], 60,
                     env=cloud_env):
            print("Не удалось прочитать mailru:; проверьте имя remote, WebDAV URL, пароль приложения и сеть. Бэкап не запускаю.")
        else:
            if not (CLOUD / "restic-password").exists():
                secret_write(CLOUD / "restic-password", secrets.token_urlsafe(48))
            if LAST.is_file():
                print("Первый успешный бэкап уже выполнен; работает расписание.")
            elif run(["systemctl", "is-active", "--quiet", "restic-backups-immich-mailru.service"]):
                print("Первый бэкап уже выполняется.")
            else:
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
