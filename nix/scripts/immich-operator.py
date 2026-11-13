"""Root-only setup and privacy-safe status for the native Immich service."""
import datetime
import fcntl
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
    archive = archive_state()
    if archive:
        phase = archive["phase"]
        if not archive_mount_ready():
            data["archive"] = "WebDAV недоступен"
        elif phase == "complete":
            data["archive"] = "Подключён · " + str(archive["count"]) + " файлов"
        elif phase == "review":
            data["archive"] = "Требует проверки"
        else:
            data["archive"] = "Индексируется"
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
            ["runuser", "-u", "postgres", "--", os.environ["IMMICH_OPERATOR_PSQL"], "-X", "-qAt",
             "-v", "ON_ERROR_STOP=1", "--host=/run/postgresql", "--username=postgres",
             "--dbname", os.environ["IMMICH_OPERATOR_DB"],
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
    except SetupError as e:
        # Do not rotate a working key on transient API/network/server failures.
        if str(e).endswith(("HTTP 401", "HTTP 403")):
            return False
        raise
    except OSError:
        raise SetupError("Не удалось прочитать существующий ключ статистики.") from None


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


ARCHIVE_MOUNT = "/mnt/immich-family-archive"
ARCHIVE_NAME = "Mail.ru external family archive"
ARCHIVE_EXTENSIONS = set((".3fr .ari .arw .cap .cin .cr2 .cr3 .crw .dcr .dng .erf .fff .iiq .k25 .kdc .mrw .nef .nrw .orf .ori .pef .psd .raf .raw .rw2 .rwl .sr2 .srf .srw .x3f .avif .bmp .gif .jfif .jpeg .jpg .png .webp .heic .heif .hif .insp .jp2 .jpe .jxl .mpo .svg .tif .tiff .3gp .3gpp .avi .flv .insv .m2t .m2ts .m4v .mkv .mov .mp4 .mpe .mpeg .mpg .mts .mxf .ts .vob .webm .wmv").split())


def archive_state():
    try:
        return json.loads((STATE / "archive-state.json").read_text())
    except FileNotFoundError:
        return None


def save_archive(data):
    fd, name = tempfile.mkstemp(dir=STATE)
    try:
        with os.fdopen(fd, "w") as out:
            json.dump(data, out, ensure_ascii=False)
        os.replace(name, STATE / "archive-state.json")
    finally:
        if os.path.exists(name):
            os.unlink(name)


def archive_remote(value):
    # Only a specific folder, never account root or the encrypted backup.
    value = value.strip().strip("/")
    if not value or any(x in ("", ".", "..") for x in value.split("/")) or any(c in value for c in "\r\n\0:"):
        raise SetupError("Укажите конкретную папку внутри Mail.ru.")
    if value.split("/")[0].casefold() == "immichbackups":
        raise SetupError("Нельзя подключать каталог резервных копий.")
    return "mailru:" + value


def archive_manifest(remote, env):
    try:
        raw = subprocess.check_output(["rclone", "--config", str(CLOUD / "rclone.conf"),
            "lsjson", "--recursive", "--files-only", remote], env=env,
            stderr=subprocess.DEVNULL, timeout=300, text=True)
        files = json.loads(raw)
    except (OSError, ValueError, subprocess.SubprocessError):
        raise SetupError("Не удалось получить полный список файлов архива.") from None
    result = []
    for entry in files:
        p = entry["Path"]
        parts = p.split("/")
        if any(x in ("", ".", "..") or x.startswith(".") or x.casefold() in
               ("@eadir", "#recycle", "#snapshot") for x in parts):
            continue
        if Path(p).suffix.lower() in ARCHIVE_EXTENSIONS:
            result.append(ARCHIVE_MOUNT + "/" + p)
    return sorted(set(result))


def archive_mount_ready():
    return run(["systemctl", "is-active", "--quiet", "immich-family-archive.service"]) and run(
        ["mountpoint", "-q", ARCHIVE_MOUNT])


def archive_rows(library, album):
    # UUID validation prevents interpolation of arbitrary SQL. Only read IDs,
    # paths and membership, never write directly to Immich's database.
    import uuid
    library, album = str(uuid.UUID(library)), str(uuid.UUID(album))
    sql = f"""SELECT COALESCE(json_agg(json_build_object(
      'id', a.id, 'path', a."originalPath", 'member', aa."assetId" IS NOT NULL,
      'visible', a.visibility != 'hidden'))
      , '[]'::json) FROM public.asset a
      LEFT JOIN public.album_asset aa ON aa."assetId" = a.id AND aa."albumId" = '{album}'
      WHERE a."libraryId" = '{library}' AND a."deletedAt" IS NULL
      AND NOT a."isOffline" AND a.status = 'active';"""
    try:
        raw = subprocess.check_output(["runuser", "-u", "postgres", "--",
            os.environ["IMMICH_OPERATOR_PSQL"], "-X", "-qAt", "-v", "ON_ERROR_STOP=1",
            "--host=/run/postgresql", "--username=postgres",
            "--dbname", os.environ["IMMICH_OPERATOR_DB"], "-c", "BEGIN READ ONLY; " + sql + " COMMIT;"],
            stderr=subprocess.DEVNULL, timeout=60, text=True,
            env={**os.environ, "PGOPTIONS": "-c default_transaction_read_only=on"})
        return json.loads(raw)
    except (OSError, ValueError, KeyError, subprocess.SubprocessError):
        raise SetupError("Не удалось проверить индекс архива.") from None


def archive_plan(expected, rows):
    """Strict completeness: never treat a partial cloud crawl as success."""
    found = {r["path"]: r for r in rows}
    missing = set(expected) - set(found)
    unexpected = set(found) - set(expected)
    # Hidden Live Photo companion assets need not be added separately.
    pending = [r["id"] for p, r in found.items()
               if p in expected and r["visible"] and not r["member"]]
    return missing, unexpected, pending


def archive_key(token, label, permissions):
    key = api("/api-keys", "POST", {"name": label, "permissions": permissions + ["apiKey.delete"]},
              token=token)
    return {"id": key["id"], "secret": key["secret"]}


def archive_revoke(data, field):
    key = data.get(field)
    if not key:
        return
    try:
        api("/api-keys/" + key["id"], "DELETE", key=key["secret"])
    except SetupError as e:
        # A revoked/expired key no longer needs cleanup. Other failures retry.
        if not str(e).endswith(("HTTP 401", "HTTP 403", "HTTP 404")):
            raise
    data.pop(field, None)
    save_archive(data)


def configure_archive():
    data = archive_state()
    if data and data.get("phase") == "complete":
        print("Семейный архив уже проиндексирован и добавлен в альбом. Пропускаю.")
        return
    if data and data.get("phase") in ("queued", "indexing", "adding"):
        print("Семейный архив: первоначальная индексация/добавление выполняется в фоне.")
        return
    if data and data.get("phase") == "review":
        print("Архив требует проверки: " + data.get("reason", "неполный индекс") +
              ". Повторное сканирование автоматически не запускается.")
        return
    if not (CLOUD / "rclone.conf").is_file():
        return
    if not ask("Подключить старый семейный архив Mail.ru напрямую, без копирования оригиналов?"):
        return
    env = prepare_cloud()
    if env is None:
        return
    selection = read_selection()
    users = inventory()
    family = existing_family(users, selection)
    if not family:
        raise SetupError("Сначала настройте общий семейный альбом.")
    remote_file = STATE / "archive-remote"
    if remote_file.exists():
        remote = remote_file.read_text().strip()
        # Validate persisted choice, never silently change an existing mount.
        if not remote.startswith("mailru:") or archive_remote(remote[7:]) != remote:
            raise SetupError("Некорректный путь существующего архива.")
    else:
        remote = archive_remote(input("Путь семейной папки в Mail.ru (от корня облака): "))
    expected = archive_manifest(remote, env)
    if not expected:
        raise SetupError("В выбранной папке не найдено поддерживаемых фотографий или видео.")
    print(f"Найдено медиафайлов: {len(expected)}. Альбом: {family['name']}.")
    print("ВНИМАНИЕ: если альбом уже опубликован, добавленные фото станут видны по существующей ссылке.")
    if not ask("Подтвердить добавление ВСЕХ найденных фото и видео в этот альбом?"):
        return
    if not remote_file.exists():
        secret_write(remote_file, remote)
    if not run(["systemctl", "start", "immich-family-archive.service"], timeout=110) or not archive_mount_ready():
        raise SetupError("WebDAV-монтирование не готово. Проверьте immich-family-archive.service.")
    admin = select_existing([u for u in users["users"] if u["isAdmin"]], selection.get("admin"), "Администратор")
    owner = next(u for u in users["users"] if u["id"] == family["owner"])
    admin_token = owner_token = None
    try:
        admin_token = login(admin["email"], password("Пароль администратора (однократное создание внешней библиотеки): "))["accessToken"]
        owner_token = login(owner["email"], password("Пароль владельца альбома (однократное добавление архива): "))["accessToken"]
        # Immich's scheduled scan/watch settings are global. Disable both
        # before creating the library; never run a destructive full scan on
        # an unreliable mount. Preserve all unrelated settings.
        cfg = api("/system-config", token=admin_token)
        if cfg["library"]["scan"]["enabled"] or cfg["library"]["watch"]["enabled"]:
            if not ask("Отключить автоматическое сканирование и наблюдение ВСЕХ внешних библиотек Immich?"):
                raise SetupError("Без отключения автоматических сканирований архив не подключаю.")
            cfg["library"]["scan"]["enabled"] = False
            cfg["library"]["watch"]["enabled"] = False
            api("/system-config", "PUT", cfg, token=admin_token)
        libraries = api("/libraries", token=admin_token)
        matches = [l for l in libraries if ARCHIVE_MOUNT in l["importPaths"]]
        if len(matches) > 1 or any(l["ownerId"] != family["owner"] or
                l["importPaths"] != [ARCHIVE_MOUNT] for l in matches):
            raise SetupError("Внешняя библиотека уже связана с другим владельцем или путём.")
        if matches:
            library = matches[0]
        else:
            library = api("/libraries", "POST", {"ownerId": family["owner"],
                         "name": ARCHIVE_NAME, "importPaths": [ARCHIVE_MOUNT]}, token=admin_token)
        validation = api("/libraries/" + library["id"] + "/validate", "POST",
                         {"importPaths": [ARCHIVE_MOUNT]}, token=admin_token)
        if not validation["importPaths"][0]["isValid"]:
            raise SetupError("Immich не видит WebDAV в своём пространстве монтирования. Проверьте доступ.")
        q = api("/queues/library", token=admin_token)
        if q["isPaused"] or any(q["statistics"][k] for k in ("active", "waiting", "delayed", "paused")):
            raise SetupError("Очередь внешних библиотек занята или приостановлена.")
        data = {"phase": "preparing", "library": library["id"], "album": family["id"],
                "owner": family["owner"], "editor": family["editor"], "expected": expected,
                "previousRefresh": library["refreshedAt"], "failed": q["statistics"]["failed"]}
        save_archive(data)
        data["adminKey"] = archive_key(admin_token, "nixos-archive-index-check", ["library.read", "queue.read"])
        save_archive(data)
        data["ownerKey"] = archive_key(owner_token, "nixos-archive-album-add", ["albumAsset.create", "asset.share"])
        save_archive(data)
        # Persist before dispatch: never rescan automatically after an
        # ambiguous network failure or reboot between dispatch and response.
        data["phase"] = "queued"
        save_archive(data)
        api("/libraries/" + library["id"] + "/scan", "POST", token=admin_token)
        print("Первичная индексация запущена. Добавление в альбом завершится автоматически.")
    finally:
        for token in (owner_token, admin_token):
            if token:
                try:
                    api("/auth/logout", "POST", token=token)
                except SetupError:
                    pass


def archive_worker():
    data = archive_state()
    if not data:
        return
    if data["phase"] == "complete":
        for field in ("ownerKey", "adminKey"):
            archive_revoke(data, field)
        return
    if data["phase"] not in ("queued", "indexing", "adding"):
        return
    if not archive_mount_ready():
        return
    # Guard against changed selected album or sharing permissions mid-import.
    family = existing_family(inventory(), {"album": data["album"], "owner": data["owner"], "editor": data["editor"]})
    if not family:
        data.update(phase="review", reason="Состав общего альбома изменился.")
        save_archive(data)
        return
    q = api("/queues/library", key=data["adminKey"]["secret"])
    if q["isPaused"] or any(q["statistics"][k] for k in ("active", "waiting", "delayed", "paused")):
        return
    library = api("/libraries/" + data["library"], key=data["adminKey"]["secret"])
    if library["ownerId"] != data["owner"] or library["importPaths"] != [ARCHIVE_MOUNT]:
        data.update(phase="review", reason="Изменились параметры внешней библиотеки.")
        save_archive(data)
        return
    if not library["refreshedAt"] or library["refreshedAt"] == data["previousRefresh"]:
        return
    rows = archive_rows(data["library"], data["album"])
    missing, unexpected, pending = archive_plan(data["expected"], rows)
    if missing or unexpected or q["statistics"]["failed"] > data["failed"]:
        data.update(phase="review", reason=f"Не проиндексировано: {len(missing)}, лишних: {len(unexpected)}. Проверьте очередь Library.")
        save_archive(data)
        return
    data["phase"] = "adding"
    save_archive(data)
    for offset in range(0, len(pending), 100):
        ids = pending[offset:offset+100]
        result = api("/albums/" + data["album"] + "/assets", "PUT", {"ids": ids},
                     key=data["ownerKey"]["secret"])
        if {x["id"] for x in result} != set(ids) or any(not x["success"] and x.get("error") != "duplicate" for x in result):
            raise SetupError("Не удалось добавить часть фотографий; следующая проверка продолжит с отсутствующих.")
    missing, unexpected, pending = archive_plan(data["expected"], archive_rows(data["library"], data["album"]))
    if not missing and not unexpected and not pending:
        data.update(phase="complete", count=len(data["expected"]))
        data.pop("expected", None)
        save_archive(data)
        for field in ("ownerKey", "adminKey"):
            archive_revoke(data, field)
        print("Семейный архив добавлен в общий альбом.")


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
    configure_archive()
    print("Публичные ссылки не создаются автоматически.")
    doctor()


def main():
    if sys.argv[1:] == ["self-test"]:
        assert fresh_status(None, 1) == "Нет успешного бэкапа"
        assert fresh_status(1, 2) == "Актуален"
        assert fresh_status(1, 200000) == "Проверьте бэкап"
        return
    if os.geteuid() != 0:
        raise SetupError("Используйте sudo.")
    if sys.argv[1:] in (["setup"], ["archive-worker"]):
        STATE.mkdir(mode=0o700, parents=True, exist_ok=True)
        with (STATE / "setup.lock").open("a") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                print("Мастер или обработчик архива уже выполняется.")
                return
            if sys.argv[1:] == ["setup"]:
                setup()
            else:
                archive_worker()
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
