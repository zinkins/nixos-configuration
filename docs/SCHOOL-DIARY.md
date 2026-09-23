# Electronic diary on family.home

The `Электронный дневник` tile shows upcoming lessons and homework copied from the open school diary. Clicking the tile opens the school site. School and Gosuslugi authentication stay in Yandex Browser; the importer does not copy login details, cookies, marks, profile names, attachment links, or files.

## Set up in Yandex Browser

1. After deploying this configuration, open `http://family.home/school-diary/import` in Yandex Browser.
2. Show the bookmarks bar, then drag **Обновить дневник** to it. This is a JavaScript bookmark, not a browser extension.
3. Open the school diary in Yandex Browser and sign in normally if the school's session has expired.
4. Open the week with the required lessons and click **Обновить дневник** on the bookmarks bar. The browser opens `family.home` and confirms when the data is saved.
5. Return to `http://family.home`. The tile refreshes within a minute. Repeat step 4 when the timetable or homework changes, or when a new week begins.

The bookmark reads only the days currently rendered in the open diary. If the school changes the page structure, the bookmark reports that it could not find lessons; its selectors in `nix/school-diary/bookmarklet.js` may need updating. The school site blocks embedding, so an iframe is not used.

## Data and access

The browser sends dates, lesson numbers, times, subjects, and homework text to `family.home` once per click. No background polling of the school site occurs. Saved data survives NixOS rebuilds in the systemd `school-diary` state directory. The service listens on loopback port 8084, and Caddy exposes only its `/school-diary/` path through the existing `family.home` host. Updates require the locally generated bookmark token and a page opened at `http://family.home`.

`family.home` uses HTTP and is available to LAN clients. Anyone who can open it can see the saved timetable and homework. Do not put private details in assignments copied from the school site if that LAN visibility is unsuitable.

The tile displays an update time. When the copied week has no remaining lessons, it prompts for another update. The school browser session is reused until the school or Gosuslugi expires it; the server cannot prolong that session.

## Verify after deployment

```bash
systemctl status school-diary --no-pager
curl -H 'Host: family.home' http://127.0.0.1/school-diary/data
```

Before the first import, the API returns a single `Нет данных` item. After importing, it returns the update time and upcoming lessons. No school credentials should appear in the service state or journal.
