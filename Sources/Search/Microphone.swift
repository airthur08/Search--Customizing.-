import Foundation

// The Mac's own microphone, whenever a page asks for "a microphone" without
// naming one. Left to macOS, a page gets whatever input is the system's
// default at that moment — AirPods, the moment they connect, which drops
// their sound to call quality and the voice to a telephone's. A page that
// names a device — its own picker, a choice in its settings — still gets
// the one it named.
//
// Device names only reach a page once it has been allowed a microphone, so
// the very first call on a site goes to the default; every one after that
// goes to the built-in one.
enum BuiltInMic {
    static let script = """
    (() => {
      const md = navigator.mediaDevices;
      if (!md || typeof md.getUserMedia !== 'function' || md.__searchMic) return;
      Object.defineProperty(md, '__searchMic', { value: true });
      const original = md.getUserMedia.bind(md);
      const builtIn = /built-?in|macbook|imac|mac mini|mac studio|mac pro/i;
      const pick = async () => {
        try {
          const list = await md.enumerateDevices();
          const mic = list.find(d => d.kind === 'audioinput' && builtIn.test(d.label));
          return mic ? mic.deviceId : null;
        } catch (e) { return null; }
      };
      md.getUserMedia = async function (constraints) {
        if (constraints && constraints.audio) {
          const audio = constraints.audio === true ? {} : constraints.audio;
          if (typeof audio === 'object' && audio.deviceId === undefined) {
            const id = await pick();
            if (id) constraints = Object.assign({}, constraints, { audio: Object.assign({}, audio, { deviceId: { exact: id } }) });
          }
        }
        return original(constraints);
      };
    })();
    """
}
