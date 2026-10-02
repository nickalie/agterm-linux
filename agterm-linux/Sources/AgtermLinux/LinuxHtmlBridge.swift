import Foundation
import agtermCore

/// LinuxHtmlBridge lets a file page run agterm commands, as `HtmlOverlayBridge` does on macOS. WebKitGTK names
/// no frame on a script message, so the native handler exists only in agterm's isolated world, which neither
/// page scripts nor frames reach. A `--js` page's `agterm.request` posts to its own window, and the relay in
/// that world forwards only messages whose source is the top window itself.
@MainActor
enum LinuxHtmlBridge {
    // submit and click listeners run in the capture phase and cancel the default before anything awaits, so a
    // tagged form never navigates. A button inside a tagged form belongs to the form's submit; a tagged button
    // elsewhere must be type="button", or it would submit an untagged form it sits in as well. A key is refused
    // when it would take two values, because keeping either one silently drops the other.
    static let adapterScript = """
        (() => {
          const handler = window.webkit.messageHandlers.agterm;
          const show = (el, text) => {
            const selector = el.getAttribute('data-agterm-into');
            const into = selector ? document.querySelector(selector) : null;
            if (into) into.textContent = text;
          };
          const shown = (result) => {
            if (result && typeof result.text === 'string') return result.text;
            return JSON.stringify(result ?? {});
          };
          const formArgs = (form, args, submitter) => {
            const seen = new Set();
            for (const control of form.elements) {
              const name = control.name;
              if (!name || control.matches(':disabled')) continue;
              const type = (control.type || '').toLowerCase();
              if (['submit', 'button', 'reset', 'image'].includes(type) && control !== submitter) continue;
              if (type === 'file') throw new Error(`file inputs are not supported: ${name}`);
              if (type === 'radio' && !control.checked) continue;
              let value;
              if (type === 'checkbox') {
                value = control.checked;
              } else if (type === 'number') {
                if (control.value === '') continue;
                value = control.valueAsNumber;
                if (!Number.isFinite(value)) throw new Error(`not a number: ${name}`);
              } else if (control instanceof HTMLSelectElement && control.multiple) {
                const picked = Array.from(control.selectedOptions);
                if (picked.length > 1) throw new Error(`more than one value for ${name}`);
                if (picked.length === 0) continue;
                value = picked[0].value;
              } else {
                value = control.value;
              }
              if (seen.has(name)) throw new Error(`more than one value for ${name}`);
              seen.add(name);
              args[name] = value;
            }
            return args;
          };
          const send = (el, form, submitter) => {
            const body = {cmd: el.getAttribute('data-agterm')};
            const target = el.getAttribute('data-agterm-target');
            if (target !== null) body.target = target;
            try {
              const base = el.getAttribute('data-agterm-args');
              let args = base === null ? undefined : JSON.parse(base);
              if (form) args = formArgs(form, args ?? {}, submitter);
              if (args !== undefined) body.args = args;
            } catch (error) {
              show(el, error.message);
              return;
            }
            handler.postMessage(body).then((result) => show(el, shown(result)), (error) => show(el, error.message));
          };
          document.addEventListener('submit', (event) => {
            const form = event.target;
            if (!(form instanceof HTMLFormElement) || !form.hasAttribute('data-agterm')) return;
            event.preventDefault();
            send(form, form, event.submitter);
          }, true);
          document.addEventListener('click', (event) => {
            const el = event.target instanceof Element ? event.target.closest('[data-agterm]') : null;
            if (!el || el instanceof HTMLFormElement || el.closest('form[data-agterm]')) return;
            if (el instanceof HTMLButtonElement && el.type !== 'button') return;
            event.preventDefault();
            send(el, null, null);
          }, true);
        })();
        """

    // a frame posting to its parent has its own window as the source, so it never gets through
    static let relayScript = """
        (() => {
          const handler = window.webkit.messageHandlers.agterm;
          window.addEventListener('message', (event) => {
            const data = event.data;
            if (event.source !== window || !data || data.agterm !== 'request') return;
            const answer = (fields) => window.postMessage(Object.assign({agterm: 'reply', id: data.id}, fields), '*');
            handler.postMessage(data.body).then((result) => answer({result}),
              (error) => answer({error: String((error && error.message) || error)}));
          });
        })();
        """

    // the page's own entry point; the second argument is the request envelope, not the arguments themselves
    static let helperScript = """
        (() => {
          let next = 0;
          const waiting = new Map();
          window.addEventListener('message', (event) => {
            const data = event.data;
            if (event.source !== window || !data || data.agterm !== 'reply' || !waiting.has(data.id)) return;
            const {resolve, reject} = waiting.get(data.id);
            waiting.delete(data.id);
            if (typeof data.error === 'string') reject(new Error(data.error)); else resolve(data.result);
          });
          const request = (cmd, {target, args} = {}) => new Promise((resolve, reject) => {
            const body = {cmd};
            if (target !== undefined) body.target = target;
            if (args !== undefined) body.args = args;
            const id = ++next;
            waiting.set(id, {resolve, reject});
            try {
              window.postMessage({agterm: 'request', id, body}, '*');
            } catch (error) {
              waiting.delete(id);
              reject(error);
            }
          });
          Object.defineProperty(window, 'agterm', {value: Object.freeze({request}), enumerable: false});
        })();
        """

    /// reply shapes a response for the page: the result as a JSON object, or the error for a refused request.
    static func reply(_ response: ControlResponse) -> (json: String?, error: String?) {
        guard response.ok else { return (nil, response.error ?? "request failed") }
        guard let result = response.result, let data = try? JSONEncoder().encode(result),
              let text = String(data: data, encoding: .utf8) else { return ("{}", nil) }
        return (text, nil)
    }

    /// request turns a page message into the socket's request, filled from where the page sits now.
    static func request(json: String, page: HtmlBridgePage) -> Result<ControlRequest, LinuxBridgeRefusal> {
        guard let data = json.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
            return .failure(LinuxBridgeRefusal(message: "invalid request"))
        }
        return HtmlBridge.request(from: data, page: page).mapError { LinuxBridgeRefusal(message: $0.message) }
    }
}

struct LinuxBridgeRefusal: Error, Equatable {
    let message: String
}
