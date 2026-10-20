// Replays a recorded run.ps1 transcript line by line.
// Without JavaScript the whole transcript is visible, so search engines
// and no-JS readers still get every line.
(function () {
  var reduceMotion = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  // How long to pause after a line, by its class. Lines that reached the
  // model take longer than lines the gateway refused on the spot.
  function delayFor(line) {
    var c = line.className;
    if (c.indexOf("t-title") >= 0) return 500;
    if (c.indexOf("t-base") >= 0 || c.indexOf("t-red") >= 0 || c.indexOf("t-blue") >= 0) return 700;
    if (c.indexOf("call") >= 0) return 650;
    if (c.indexOf("t-warn") >= 0) return 160;
    if (c.indexOf("t-pass") >= 0 || c.indexOf("t-fail") >= 0) return 0;
    return 90;
  }

  function setup(term) {
    // Only direct children are lines; nested spans colour parts of a line.
    var lines = Array.prototype.slice.call(term.querySelectorAll("pre > span"));
    var button = term.querySelector("button");
    var timer = null;
    var i = 0;

    function finish() {
      clearTimeout(timer);
      lines.forEach(function (l) { l.classList.remove("hidden"); });
      i = lines.length;
      button.textContent = "Replay";
    }

    function step() {
      if (i >= lines.length) { button.textContent = "Replay"; return; }
      var line = lines[i++];
      line.classList.remove("hidden");
      timer = setTimeout(step, delayFor(line));
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
