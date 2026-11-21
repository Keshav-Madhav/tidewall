#if TIDEWALL_DEV
import Cocoa
import WebKit

/// A test run (--bench): the real desk is ignored for a fixed one of pretend windows, the main page's stats are logged
/// every 3 s, and the run quits after --secs. Options add motion (--hop, --sweep, --film, --choreo) and pictures
/// (--snapshot, --frames).
final class Bench {
  private static var running: Bench?

  static func start(_ app: App) {
    running = Bench(app: app)
    running?.run()
  }

  private unowned let app: App
  private let secs = Double(argValue("--secs") ?? "12")!
  private let sweep = args.contains("--sweep")
  private let choreo = argValue("--choreo").flatMap { Choreo(path: $0) }
  /// the desk when no layout is asked for: one big window, a Stage Manager-like column and a widget
  private let defaultDesk: [CGRect] = args.contains("--nowin") ? []
    : args.contains("--small") ? [CGRect(x: 560, y: 330, width: 520, height: 360)]
    : [CGRect(x: 221, y: 70, width: 1070, height: 875)]
      + [166.0, 337, 516, 679].map { CGRect(x: 16, y: $0, width: 130, height: 160) }
      + [CGRect(x: 1324, y: 794, width: 180, height: 180)]
  private var rects: [CGRect] = []
  private var owners = ["Slack", "WhatsApp", "Notes", "Electron", "Claude", "Notification Centre"]
  private var stageCards: [CGRect] = []

  private init(app: App) {
    self.app = app
  }

  private var mainWall: Wallpaper? { app.walls.values.first { $0.cgFrame.origin == .zero } }

  private func after(_ seconds: Double, _ f: @escaping () -> Void) {
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: f)
  }

  private func run() {
    app.tracker.onUpdate = { _, _ in }   // the real, changing desk never reaches the pages
    setUpDesk()
    if !sweep {
      after(1.5) { [self] in
        for r in stageCards { Tracker.stageRects.insert("\(r)") }
        app.lastRects = rects
        app.lastOwners = owners
        app.dispatch(live: false)
      }
      if let before = argValue("--hop").flatMap(Double.init) { hop(secondsBeforeEnd: before) }
    } else {
      startSweep()
    }
    logStatsEvery3s()
    measureFamily()
    if let dir = argValue("--film") { film(into: dir) }
    if let dir = argValue("--frames") { takeFrames(into: dir) }
    if let shot = argValue("--snapshot") { snapshot(shot) }
    after(secs) { [self] in quitWhenShot(tries: 75) }
  }

  private func setUpDesk() {
    rects = defaultDesk
    if let c = choreo {
      let (r, o, sm) = c.at(0)
      rects = r
      owners = o
      stageCards = zip(r, sm).filter { $0.1 }.map { $0.0 }
      c.pinCursor(0)   // the real mouse must not reach the page while filming
    } else if argValue("--layout") == "auto", !fakeWorld.isEmpty {
      // a big and a small window on every pretend display
      let names = ["Safari", "Code", "Slack", "Notes", "Mail", "Figma"]
      rects = []
      owners = []
      for (_, f) in fakeWorld.sorted(by: { $0.key < $1.key }) {
        rects.append(CGRect(x: f.minX + f.width * 0.1, y: f.minY + max(40, f.height * 0.12), width: f.width * 0.46, height: f.height * 0.48))
        rects.append(CGRect(x: f.minX + f.width * 0.64, y: f.minY + f.height * 0.55, width: f.width * 0.24, height: f.height * 0.28))
      }
      owners = rects.indices.map { names[$0 % 6] }
    } else if let name = argValue("--layout"), let layout = BenchLayouts.all[name] {
      rects = layout.map { $0.0 }
      owners = layout.map { $0.1 }
      stageCards = layout.filter { $0.2 }.map { $0.0 }
    }
  }

  // MARK: motion

  /// --hop S: the first window glides 380, 200 pt over 0.4 s, S seconds before the run ends. tools/smooth.sh lines its
  /// frame times up with the "hop starts" line.
  private func hop(secondsBeforeEnd before: Double) {
    let start = max(2, secs - 1 - before - 0.4)
    let from = defaultDesk[0], to = from.offsetBy(dx: 380, dy: 200)
    after(start) { log(String(format: "bench: hop starts %.0f", Date().timeIntervalSince1970 * 1000)) }
    for i in 0...12 {
      after(start + Double(i) * 0.4 / 12) { [self] in
        let t = Double(i) / 12, e = t * t * (3 - 2 * t)
        app.lastRects[0] = CGRect(x: from.minX + (to.minX - from.minX) * e, y: from.minY + (to.minY - from.minY) * e,
                                  width: from.width, height: from.height)
        app.dispatch(live: i < 12)
      }
    }
  }

  /// --sweep: one window circling the main display for the whole run, to measure live updates.
  private func startSweep() {
    var t0 = 0.0
    Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [self] _ in
      if t0 == 0 { t0 = ProcessInfo.processInfo.systemUptime }
      let t = ProcessInfo.processInfo.systemUptime - t0
      guard let w = mainWall ?? app.walls.values.first else { return }
      let f = w.cgFrame
      app.lastRects = [CGRect(x: f.minX + f.width * (0.3 + 0.2 * sin(t * 1.3)), y: f.minY + f.height * (0.3 + 0.15 * cos(t)),
                              width: 700, height: 500)]
      app.dispatch(live: true)
    }
  }

  // MARK: stats

  /// What the whole run cost from 6 s in (loaded and settled) to the end: CPU and GPU of the app and every process
  /// macOS bills to it (WebKit's web content and GPU processes do the drawing), for tools/bench.sh.
  private func measureFamily() {
    let meter = Usage()
    after(6) { _ = meter.sample() }
    after(max(secs - 0.5, 6.5)) {
      let s = meter.sample()
      log(String(format: "bench usage cpu=%.1f gpu=%.1f mem=%.0f procs=%d", s.cpu, s.gpu, s.memMB, s.procs))
    }
  }

  private static let statsProbe = "(()=>{try{return [(window.__prof?('JSms/frame='+(__prof.ms/Math.max(1,__prof.n)).toFixed(2)+' frames/s='+(__prof.n/((performance.now()-__prof.t0)/1000)).toFixed(1)):''),(typeof window.__dbg==='function'?__dbg():''), (typeof icons!=='undefined'?'icon0='+JSON.stringify(icons[0]&&{x:icons[0].x|0,y:icons[0].y|0,w:icons[0].w|0,h:icons[0].h|0})+' s@c='+(typeof curS==='function'&&icons[0]?curS(icons[0].x+icons[0].w/2,icons[0].y+icons[0].h/2).toFixed(0):'-')+' frames='+(typeof frameN!=='undefined'?frameN:'-')+' icons='+icons.length+' mix='+(typeof curMix!=='undefined'?curMix.toFixed(2):'-')+' from/to='+(typeof fromI!=='undefined'?fromI+'/'+toI:'-')+' morphT0='+(typeof morphT0!=='undefined'?(morphT0|0):'-')+' FB='+(typeof FB!=='undefined'&&!!FB)+' iconsSeen='+(typeof iconsSeen!=='undefined'?iconsSeen:'-'):''), 'dpr=' + devicePixelRatio, cv.width+'x'+cv.height, cv._scale, P.quality, Math.round(fpsEMA), fieldMs.toFixed(1), (window.__gl?window.__gl.drawingBufferWidth:0)+'x'+(window.__gl?window.__gl.drawingBufferHeight:0), paused].join(' ')}catch(e){return 'page loading'}})()"

  private func logStatsEvery3s() {
    Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [self] _ in
      for w in app.walls.values where w.cgFrame.origin == .zero {
        w.web.evaluateJavaScript(Self.statsProbe) { [self] r, _ in
          let pid = webPid(w.web), polls = app.tracker.polls
          let avgPoll = String(format: "%.2f", app.tracker.pollMs / Double(max(polls, 1)))
          log("bench fps/fieldMs/buffer/paused: \(r ?? "nil")  webpid=\(pid)  polls=\(polls) avgPollMs=\(avgPoll)")
        }
      }
    }
  }

  // MARK: filming

  /// --film DIR: footage for the promo video. After --film-start s the desk moves for --film-dur s (the choreography,
  /// or the first window gliding by --film-move dx,dy) while frames are taken as fast as they come, each named by its
  /// time in ms since the film began. --film-all (with --fakescreens): every pretend display films itself.
  private func film(into dir: String) {
    let start = Double(argValue("--film-start") ?? "6")!
    let dur = Double(argValue("--film-dur") ?? "4")!
    let width = Double(argValue("--film-width") ?? "1920")!
    after(start) { [self] in
      let t0 = ProcessInfo.processInfo.systemUptime
      let k = Double(argValue("--timescale") ?? "1") ?? 1
      let clock = { (ProcessInfo.processInfo.systemUptime - t0) * k }
      if let c = choreo { play(c, clock: clock, until: dur) } else { glideFirstWindow(since: t0, for: dur) }
      let shots = !args.contains("--film-noshots")   // --film-noshots: the scripted desk only (CPU measurements)
      let encoder = DispatchQueue(label: "film", qos: .userInitiated, attributes: .concurrent)
      if args.contains("--film-all") {
        if shots { for id in app.walls.keys { shoot(id, dir: dir, width: width, clock: clock, until: dur, encoder: encoder) } }
        writeLayout(to: "\(dir)/layout.json")
      } else if shots {
        shoot(nil, dir: dir, width: width, clock: clock, until: dur, encoder: encoder)
      }
    }
  }

  private func play(_ c: Choreo, clock: @escaping () -> Double, until dur: Double) {
    var prev: [CGRect] = []
    Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [self] timer in
      let t = clock(), (r, o, sm) = c.at(t)
      Tracker.stageRects = Set(zip(r, sm).filter { $0.1 }.map { "\($0.0)" })
      app.lastRects = r
      app.lastOwners = o
      app.dispatch(live: r != prev && r.count == prev.count)
      prev = r
      c.pinCursor(t)
      if let p = c.cursor(t), let w = mainWall { w.cursor(p) }
      if t > dur {
        timer.invalidate()
        app.dispatch(live: false)
      }
    }
  }

  private func glideFirstWindow(since t0: Double, for dur: Double) {
    let move = (argValue("--film-move") ?? "320,140").split(separator: ",").compactMap { Double($0) }
    let from = rects.first ?? .zero, a = 0.35, b = dur - 0.7
    Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [self] timer in
      let t = ProcessInfo.processInfo.systemUptime - t0
      let u = max(0, min(1, (t - a) / (b - a))), e = u * u * u * (u * (u * 6 - 15) + 10)   // smootherstep
      app.lastRects[0] = CGRect(x: from.minX + move[0] * e, y: from.minY + move[1] * e, width: from.width, height: from.height)
      app.dispatch(live: t > a && t < b)
      if t > dur {
        timer.invalidate()
        app.dispatch(live: false)
      }
    }
  }

  /// One frame, then the next as soon as it's taken; JPEG encoding happens off the main thread.
  private func shoot(_ id: CGDirectDisplayID?, dir: String, width: Double, clock: @escaping () -> Double, until dur: Double,
                     encoder: DispatchQueue) {
    let t = clock()
    guard t <= dur, let w = id.flatMap({ app.walls[$0] }) ?? mainWall else { return }
    let cfg = WKSnapshotConfiguration()
    cfg.snapshotWidth = NSNumber(value: width / 2)   // points: twice that in pixels on a retina screen
    w.web.takeSnapshot(with: cfg) { [self] img, _ in
      shoot(id, dir: dir, width: width, clock: clock, until: dur, encoder: encoder)
      guard let img, let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
      let name = id.map { String(format: "%@/t%06d-%d.jpg", dir, Int(t * 1000), Int($0)) } ?? String(format: "%@/t%06d.jpg", dir, Int(t * 1000))
      encoder.async {
        let jpeg = NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: 0.94])!
        try? jpeg.write(to: URL(fileURLWithPath: name))
      }
    }
  }

  // MARK: pictures

  /// --frames DIR [--every S] [--from S]: a numbered picture every S seconds, to watch motion frame by frame.
  private func takeFrames(into dir: String) {
    let every = Double(argValue("--every") ?? "0.25")!, start = Double(argValue("--from") ?? "6")!
    var n = 0
    after(start) { [self] in
      Timer.scheduledTimer(withTimeInterval: every, repeats: true) { [self] _ in
        guard let w = mainWall else { return }
        let i = n
        n += 1
        let cfg = WKSnapshotConfiguration()
        cfg.snapshotWidth = 756
        w.web.takeSnapshot(with: cfg) { img, _ in img?.writePNG(to: String(format: "%@/f%04d.png", dir, i)) }
      }
    }
  }

  /// --snapshot FILE: the main page a second before the run ends, a pretend cursor circling in open sea meanwhile.
  /// With pretend displays: one picture each (FILE-<id>.png) and the desk they make (FILE-layout.json).
  private func snapshot(_ shot: String) {
    var a = 0.0
    Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [self] _ in
      a += 0.035
      mainWall?.cursor(CGPoint(x: 1380 + 70 * cos(a), y: 330 + 160 * sin(a * 0.5)))
    }
    after(secs - 1) { [self] in
      if !fakeWorld.isEmpty {
        let base = (shot as NSString).deletingPathExtension
        for (id, w) in app.walls { take(w, to: "\(base)-\(id).png") }
        writeLayout(to: "\(base)-layout.json")
        log("snapshots -> \(base)-*.png")
      } else if let w = mainWall {
        take(w, to: shot) { log("snapshot -> \(shot)") }
      }
    }
  }

  private func take(_ w: Wallpaper, to path: String, then done: @escaping () -> Void = {}) {
    shotsPending += 1
    w.web.takeSnapshot(with: nil) { img, _ in
      shotsPending -= 1
      if img?.writePNG(to: path) == true { done() }
    }
  }

  private func writeLayout(to path: String) {
    let frames = app.walls.map { id, w in
      let f = w.cgFrame
      return "\"\(id)\":[\(Int(f.minX)),\(Int(f.minY)),\(Int(f.width)),\(Int(f.height))]"
    }
    try? "{\(frames.joined(separator: ","))}".write(toFile: path, atomically: true, encoding: .utf8)
  }

  /// Pictures still being taken get up to 15 s more: even a heavy page makes its picture.
  private func quitWhenShot(tries: Int) {
    guard shotsPending > 0 && tries > 0 else { return NSApp.terminate(nil) }
    after(0.2) { [self] in quitWhenShot(tries: tries - 1) }
  }
}
#endif
