import AppKit
import WebKit

private struct TraceFailure: Error { let message: String }

private enum ScrollInstrumentation {
    static let source = #"""
    (() => {
      if (window.__scrollOwnershipTrace) return;
      window.__scrollOwnershipTrace = true;
      const nativeRAF=window.requestAnimationFrame.bind(window);
      const events=[]; const nodeIDs=new WeakMap();let nextNode=1;let actor='';
      const nodeID=node=>{if(!node)return null;if(!nodeIDs.has(node))nodeIDs.set(node,nextNode++);return nodeIDs.get(node)};
      const postID=node=>node?.querySelector?.('a:has(time)')?.href?.match(/\/status\/(\d+)/)?.[1]||null;
      const cells=()=>[...document.querySelectorAll('[data-testid=cellInnerDiv]:has(article[data-testid=tweet])')];
      window.__traceSnapshot=()=>({y:scrollY,url:location.href,hidden:document.hidden,focused:document.hasFocus(),owner:window.__tfOwner?.(),height:innerHeight,cells:cells().map(n=>({node:nodeID(n),id:postID(n),top:n.getBoundingClientRect().top,height:n.getBoundingClientRect().height,connected:n.isConnected}))});
      const record=(kind,data={})=>{events.push({t:performance.now(),kind,actor,y:scrollY,url:location.href,...data});if(events.length>5000)events.shift()};
      window.__trace=record;window.__traceEvents=events;
      const identify=stack=>actor||(/restoreFrame/.test(stack)?'restoreFrame':/step@/.test(stack)?'key-rAF':'other-programmatic');
      for(const method of ['scrollTo','scrollBy']) {
        const original=window[method].bind(window);
        window[method]=function(...args){const stack=new Error().stack;const before=scrollY;const result=original(...args);record('scroll-write',{method,owner:identify(stack),before,after:scrollY,args,stack});return result};
      }
      const into=Element.prototype.scrollIntoView;
      Element.prototype.scrollIntoView=function(...args){const stack=new Error().stack;record('scroll-write',{method:'scrollIntoView',owner:actor||'wheel-snap/browser-smooth',node:nodeID(this),post:postID(this),args,stack});return into.apply(this,args)};
      let post=window.__perchPost;
      Object.defineProperty(window,'__perchPost',{configurable:true,get(){return post},set(value){post=function(body){if(['ready','intent','fitPost','mode','saveSession','refreshHome','back'].includes(body.type))record('native-request',{body});return value(body)}}});
      let didFit=window.__tfDidFit;const acks=[];window.__traceHoldAcks=false;
      const applyAck=args=>{record('native-ack-apply',{args});const old=actor;actor='fit-ack';try{return didFit(...args)}finally{actor=old}};
      Object.defineProperty(window,'__tfDidFit',{configurable:true,get(){return didFit && ((...args)=>{record('native-ack-arrive',{args,held:window.__traceHoldAcks});if(window.__traceHoldAcks){acks.push(args);return}return applyAck(args)})},set(value){didFit=value}});
      for(const hook of ['__tfCheckpoint','__tfActivate','__tfRestorePosition']) {
        let implementation=window[hook];
        Object.defineProperty(window,hook,{configurable:true,get(){return implementation && function(...args){record('lifecycle-call',{hook,args,owner:window.__tfOwner?.()});const result=implementation(...args);record('lifecycle-return',{hook,result,owner:window.__tfOwner?.()});return result}},set(value){implementation=value}});
      }
      window.__traceAckCount=()=>acks.length;
      window.__traceFlushAcks=()=>{window.__traceHoldAcks=false;for(const args of acks.splice(0))applyAck(args)};
      window.__tracePauseFrames=false;const frames=[];
      window.requestAnimationFrame=callback=>nativeRAF(time=>{if(window.__tracePauseFrames){frames.push(callback);record('frame-held');return}callback(time)});
      window.__traceResumeFrames=()=>{window.__tracePauseFrames=false;for(const callback of frames.splice(0))nativeRAF(callback)};
      for(const type of ['wheel','pointerdown','keydown','click','resize','scroll','popstate','pagehide','visibilitychange','focus','blur'])
        window.addEventListener(type,event=>record('event',{type,key:event.key,deltaY:event.deltaY,trusted:event.isTrusted,hidden:document.hidden}),{capture:true,passive:true});
      for(const method of ['pushState','replaceState']){const original=history[method].bind(history);history[method]=function(...args){record('history',{method,args});return original(...args)}}
      window.__traceWithActor=(name,fn)=>{const old=actor;actor=name;try{return fn()}finally{actor=old}};
    })();
    """#
}

@MainActor
private final class ScrollTrace: NSObject, NSApplicationDelegate {
    var widget: XWidget!
    var suites: [String] = []
    var scenes: [[String: Any]] = []
    var safetyTimer: Timer?
    var foregroundSamples: [[String: Any]] = []
    let home = URL(string: CommandLine.arguments[1] + "/home")!
    let output = URL(fileURLWithPath: CommandLine.arguments[2])

    func applicationDidFinishLaunching(_ notification: Notification) {
        safetyTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let foreground = NSWorkspace.shared.frontmostApplication
                self.foregroundSamples.append(["pid": foreground?.processIdentifier ?? -1,
                                               "bundle": foreground?.bundleIdentifier ?? "",
                                               "panelHeight": self.widget?.panel.frame.height ?? 0])
                let failures = OffscreenHost.safetyFailures()
                if foreground?.processIdentifier == ProcessInfo.processInfo.processIdentifier || !failures.isEmpty {
                    print("FAIL nonactivating boundary: \(failures)")
                    self.cleanup(); exit(1)
                }
            }
        }
        Task {
            do {
                if CommandLine.arguments.contains("--probe") {
                    try await probe()
                    cleanup(); exit(0)
                }
                if CommandLine.arguments.contains("--snapshots") {
                    try await captureSnapshots()
                    cleanup(); exit(0)
                }
                try await staleAcknowledgement()
                try await recycledNode()
                try await suspendedFocusReturn()
                try save()
                cleanup(); exit(0)
            } catch {
                print("FAIL \(error)"); try? save(); cleanup(); exit(1)
            }
        }
    }
    func cleanup() {
        safetyTimer?.invalidate()
        widget?.close()
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    }
    func pause(_ seconds: Double) async throws { try await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }
    func js(_ code: String) async throws -> Any? { try await widget.webView!.evaluateJavaScript(code) }
    func wait(_ code: String) async throws {
        for _ in 0..<70 { if try await js(code) as? Bool == true { return }; try await pause(0.1) }
        throw TraceFailure(message: "Timed out: \(code)")
    }
    func fresh() async throws {
        widget?.close()
        let suite = "local.perch.scroll-ownership.\(UUID().uuidString)"; suites.append(suite)
        let prefs = UserDefaults(suiteName: suite)!
        prefs.set("dark", forKey: "feedTheme")
        widget = XWidget(home: home, defaults: prefs, dataStore: .nonPersistent())
        OffscreenHost.isActive = true
        OffscreenHost.show(widget)
        widget.webView!.configuration.userContentController.addUserScript(WKUserScript(source: ScrollInstrumentation.source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        try await wait("document.querySelectorAll('article[data-testid=tweet]').length===6 && window.__traceEvents !== undefined")
        try await pause(0.8)
    }
    func scene(_ name: String, proof: Any?) async throws {
        let snapshot = try await js("__traceSnapshot()")
        let events = try await js("__traceEvents")
        scenes.append(["name": name, "proof": proof ?? NSNull(), "snapshot": snapshot ?? NSNull(), "events": events ?? [], "hostSafety": ["failures": OffscreenHost.safetyFailures(), "foregroundSamples": foregroundSamples, "hostPID": ProcessInfo.processInfo.processIdentifier]])
        print("SCENE \(name) \(String(describing: proof))"); fflush(stdout)
    }
    func captureSnapshots() async throws {
        try await fresh()
        var records: [[String: Any]] = []
        func capture(_ name: String) async throws {
            guard let browser = widget.webView else { throw TraceFailure(message: "No browser for snapshot") }
            let image: NSImage? = try await withCheckedThrowingContinuation { continuation in
                browser.takeSnapshot(with: nil) { image, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: image) }
                }
            }
            guard let image, let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else {
                throw TraceFailure(message: "Missing PNG snapshot")
            }
            let destination = output.deletingPathExtension().appendingPathExtension(name + ".png")
            try png.write(to: destination)
            records.append(["name": name, "file": destination.path, "page": try await js("__traceSnapshot()") ?? NSNull(),
                            "width": rep.pixelsWide, "height": rep.pixelsHigh])
        }
        try await capture("home-short")
        _ = try await js("document.body.dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowDown',bubbles:true,cancelable:true}))")
        try await pause(0.6)
        try await capture("home-tall")
        _ = try await js("document.querySelectorAll('[data-testid=cellInnerDiv]')[1].querySelector('a:has(time)').click()")
        try await wait("location.pathname==='/reader/status/10002' && document.querySelector('#comments')!==null")
        try await pause(0.5)
        try await capture("comments")
        try JSONSerialization.data(withJSONObject: ["snapshots": records, "foregroundSamples": foregroundSamples,
                                                   "hostPID": ProcessInfo.processInfo.processIdentifier,
                                                   "safetyFailures": OffscreenHost.safetyFailures()], options: [.prettyPrinted, .sortedKeys]).write(to: output)
        print("PASS three local WK snapshots (Home short/tall/comments); no desktop capture")
    }
    func probe() async throws {
        // Five-second deadline includes page creation, compositor and bridge work.
        Task { try? await Task.sleep(nanoseconds: 5_000_000_000); print("FAIL probe exceeded five seconds"); cleanup(); exit(1) }
        try await fresh()
        _ = try await js("window.__probeFrames=0;window.__probePositions=[];window.__probeStart=scrollY;requestAnimationFrame(function tick(){window.__probeFrames++;__probePositions.push(scrollY);if(window.__probeFrames<30)requestAnimationFrame(tick)});scrollTo({top:600,behavior:'smooth'})")
        try await wait("window.__probeFrames>=20 && __probePositions.some(y=>y>0&&y<600) && scrollY>0")
        _ = try await js("scrollTo({top:0,behavior:'instant'});document.querySelector('article[data-testid=tweet]').style.height='460px';__tfRefit()")
        try await wait("__traceEvents.some(e=>e.kind==='native-ack-arrive')")
        try await pause(0.35)
        let proof = try await js("({frames:__probeFrames,positions:__probePositions,start:__probeStart,final:scrollY,nativeAcks:__traceEvents.filter(e=>e.kind==='native-ack-arrive').length})")
        let record: [String: Any] = ["proof": proof ?? NSNull(), "foregroundSamples": foregroundSamples,
                                    "hostPID": ProcessInfo.processInfo.processIdentifier,
                                    "safetyFailures": OffscreenHost.safetyFailures(),
                                    "policy": "prohibited; nonactivating; alpha .001; click-through; no native input monitor"]
        try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]).write(to: output)
        print("PASS five-second nonactivating compositor/fit probe \(String(describing: proof)); samples=\(foregroundSamples.count)")
    }
    func staleAcknowledgement() async throws {
        try await fresh()
        _ = try await js("__traceEvents.length=0;__traceHoldAcks=true;__tfRefit()")
        try await wait("__traceAckCount()>0")
        let proof = try await js(#"""
        (()=>{const before=scrollY;__traceWithActor('simulated-compositor-gap',()=>scrollTo({top:130,behavior:'instant'}));const moved=scrollY;__trace('intent-gap',{note:'Compositor/page moved before a passive wheel event has been delivered'});__traceFlushAcks();return{before,moved,after:scrollY,wheelDelivered:__traceEvents.some(e=>e.kind==='event'&&e.type==='wheel')}})()
        """#)
        try await scene("pending-fit-after-compositor-gap", proof: proof)
    }
    func recycledNode() async throws {
        try await fresh()
        _ = try await js("__traceEvents.length=0;document.body.dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowDown',bubbles:true,cancelable:true}))")
        try await pause(0.06)
        let reuse = try await js(#"""
        (()=>{const cell=document.querySelectorAll('[data-testid=cellInnerDiv]')[1];const old=cell.querySelector('a:has(time)').href;cell.querySelector('a:has(time)').href='/reader/status/90002';cell.querySelector('time').textContent='Recycled row';__trace('site-node-reuse',{old,newID:'90002',connected:cell.isConnected});return{old,newID:'90002',connected:cell.isConnected}})()
        """#)
        try await pause(0.8)
        try await scene("connected-node-reused-during-key-motion", proof: reuse)
    }
    func suspendedFocusReturn() async throws {
        try await fresh()
        _ = try await js("__traceEvents.length=0;__tracePauseFrames=true;__traceHoldAcks=true;document.body.dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowDown',bubbles:true,cancelable:true}))")
        try await pause(0.06)
        _ = try await js("__traceWithActor('simulated-reading-before-away',()=>scrollTo({top:900,behavior:'instant'}));__trace('reading-before-away',{y:scrollY})")
        OffscreenHost.setActivity(widget, false)
        try await pause(0.3)
        OffscreenHost.setActivity(widget, true)
        let proof = try await js("({beforeResume:scrollY,pointerdowns:__traceEvents.filter(e=>e.kind==='event'&&e.type==='pointerdown').length})")
        _ = try await js("__traceResumeFrames()")
        try await pause(0.1)
        try await scene("simulated-suspended-frames-lifecycle-return", proof: proof)
    }
    func save() throws {
        let data = try JSONSerialization.data(withJSONObject: scenes, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: output)
    }
}

@main private struct TraceXScrolling {
    static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
        let delegate = ScrollTrace(); app.delegate = delegate; app.run()
    }
}
