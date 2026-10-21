// Replays a recorded run.ps1 transcript line by line.
// Recordings come from lab.ps1 -Record: each line carries data-t, the milliseconds
// since the run started, so the replay keeps the real pacing, sped up (data-speed on
// .terminal, default 4x) and with long waits capped so nobody watches a 15 s pause.
// Without JavaScript the whole transcript is visible, so search engines and no-JS
// readers still get every line.
(function () {
  var reduceMotion = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  var MIN_DELAY = 25, MAX_DELAY = 2500;

  // Fallback for lines without timings: pause by kind of line.
  function delayByKind(line) {
    var c = line.className;
    if (c.indexOf("t-title") >= 0) return 500;
    if (c.indexOf("t-base") >= 0 || c.indexOf("t-red") >= 0 || c.indexOf("t-blue") >= 0) return 700;
    if (c.indexOf("call") >= 0) return 650;
    if (c.indexOf("t-warn") >= 0) return 160;
    return 90;
  }

  function setup(term) {
    // Only direct children are lines; nested spans colour parts of a line.
    var lines = Array.prototype.slice.call(term.querySelectorAll("pre > span"));
    var button = term.querySelector("button");
    var speed = parseFloat(term.getAttribute("data-speed")) || 4;
    var timer = null;
    var i = 0;

    // How long to wait before showing line n: the real gap since the line before it.
    function delayBefore(n) {
      if (n === 0) return 0;
      var t = lines[n].getAttribute("data-t"), prev = lines[n - 1].getAttribute("data-t");
      if (t === null || prev === null) return delayByKind(lines[n - 1]);
      return Math.min(MAX_DELAY, Math.max(MIN_DELAY, (t - prev) / speed));
    }

    function finish() {
      clearTimeout(timer);
      lines.forEach(function (l) { l.classList.remove("hidden"); });
      i = lines.length;
      button.textContent = "Replay";
    }

    function step() {
      lines[i++].classList.remove("hidden");
      if (i >= lines.length) { button.textContent = "Replay"; return; }
      timer = setTimeout(step, delayBefore(i));
    }

    function play() {
      clearTimeout(timer);
      lines.forEach(function (l) { l.classList.add("hidden"); });
      i = 0;
      button.textContent = "Skip";
      step();
    }

    button.addEventListener("click", function () {
      if (button.textContent === "Skip") finish(); else play();
    });

    if (reduceMotion || !("IntersectionObserver" in window)) { finish(); return; }

    // Start when the terminal scrolls into view, once.
    lines.forEach(function (l) { l.classList.add("hidden"); });
    button.textContent = "Play";
    var seen = new IntersectionObserver(function (entries) {
      if (entries[0].isIntersecting) { seen.disconnect(); play(); }
    }, { threshold: 0.3 });
    seen.observe(term);
  }

  document.querySelectorAll(".terminal").forEach(setup);
})();
