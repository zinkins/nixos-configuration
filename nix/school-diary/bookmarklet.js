(() => {
  if (location.hostname !== "school.nso.ru") {
    alert("Откройте электронный дневник на school.nso.ru и повторите.");
    return;
  }

  const clean = (value) => (value || "").replace(/\s+/g, " ").trim();
  const days = [...document.querySelectorAll(".dnevnik-day")].map((day) => {
    const title = clean(day.querySelector(".dnevnik-day__title")?.textContent);
    const date = title.match(/\b\d{1,2}\.\d{1,2}\b/)?.[0];
    if (!date) return null;

    const lessons = [...day.querySelectorAll(".dnevnik-lesson")].map((lesson) => {
      const tasks = [...lesson.querySelectorAll(".dnevnik-lesson__task")].map((task) => {
        const copy = task.cloneNode(true);
        copy.querySelectorAll(".dnevnik-lesson__attach, .dnevnik-lesson-icon").forEach((node) => node.remove());
        return clean(copy.textContent);
      }).filter(Boolean);

      return {
        number: clean(lesson.querySelector(".dnevnik-lesson__number")?.textContent).replace(/\D/g, ""),
        time: clean(lesson.querySelector(".dnevnik-lesson__time")?.textContent),
        subject: clean(lesson.querySelector(".js-rt_licey-dnevnik-subject")?.textContent),
        homework: tasks.join("; "),
      };
    }).filter((lesson) => lesson.subject);

    return { date, lessons };
  }).filter((day) => day && day.lessons.length);

  if (!days.length) {
    alert("Уроки не найдены. Откройте неделю с расписанием и повторите.");
    return;
  }

  location.href = "http://family.home/school-diary/import#" + encodeURIComponent(JSON.stringify({ token: "__IMPORT_TOKEN__", days }));
})()
