/*
 Copyright 2015 XWebView

 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at

 http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
*/

import Foundation
import WebKit

public class XWVChannel : NSObject, WKScriptMessageHandler {
    public let name: String
    public let thread: NSThread!
    public let queue: dispatch_queue_t!
    private(set) public weak var webView: WKWebView?
    var typeInfo: XWVMetaObject!

    private var instances = [Int: XWVBindingObject]()
    private var userScript: XWVUserScript?
    private(set) var principal: XWVBindingObject {
        get { return instances[0]! }
        set { instances[0] = newValue }
    }

    private class var sequenceNumber: UInt {
        struct sequence{
            static var number: UInt = 0
        }
        return ++sequence.number
    }

    public convenience init(name: String?, webView: WKWebView) {
        let queue = dispatch_queue_create(nil, DISPATCH_QUEUE_SERIAL)
        self.init(name: name, webView:webView, queue: queue)
    }

    public init(name: String?, webView: WKWebView, queue: dispatch_queue_t) {
        self.name = name ?? "\(XWVChannel.sequenceNumber)"
        self.webView = webView
        self.queue = queue
        thread = nil
        webView.prepareForPlugin()
    }

    public init(name: String?, webView: WKWebView, thread: NSThread) {
        self.name = name ?? "\(XWVChannel.sequenceNumber)"
        self.webView = webView
        self.thread = thread
        queue = nil
        webView.prepareForPlugin()
    }

    public func bindPlugin(object: AnyObject, toNamespace namespace: String) -> XWVScriptObject? {
        assert(typeInfo == nil, "Channel \(name) is occupied by plugin object \(principal.plugin)")
        guard typeInfo == nil, let webView = webView else { return nil }

        webView.configuration.userContentController.addScriptMessageHandler(self, name: name)
        typeInfo = XWVMetaObject(plugin: object.dynamicType)
        let plugin = XWVBindingObject(namespace: namespace, channel: self, object: object)

        let stub = generateStub(plugin)
        let script = WKUserScript(source: (object as? XWVScripting)?.javascriptStub?(stub) ?? stub,
                                  injectionTime: WKUserScriptInjectionTime.AtDocumentStart,
                                  forMainFrameOnly: true)
        userScript = XWVUserScript(webView: webView, script: script)

        principal = plugin
        log("+Plugin object \(object) is bound to \(namespace) with channel \(name)")
        return plugin as XWVScriptObject
    }

    public func unbind() {
        guard typeInfo != nil else { return }
        let namespace = principal.namespace
        let plugin = principal.plugin
        instances.removeAll(keepCapacity: false)
        webView?.configuration.userContentController.removeScriptMessageHandlerForName(name)
        userScript = nil
        //typeInfo = nil  // FIXME: crash while instance deinit
        log("+Plugin object \(plugin) is unbound from \(namespace)")
    }

    public func userContentController(userContentController: WKUserContentController, didReceiveScriptMessage message: WKScriptMessage) {
        // A workaround for crash when postMessage(undefined)
        guard unsafeBitCast(message.body, COpaquePointer.self) != nil else { return }

        if let body = message.body as? [String: AnyObject], let opcode = body["$opcode"] as? String {
            let target = (body["$target"] as? NSNumber)?.integerValue ?? 0
            if let object = instances[target] {
                if opcode == "-" {
                    if target == 0 {
                        // Dispose plugin
                        unbind()
                    } else if let instance = instances.removeValueForKey(target) {
                        // Dispose instance
                        log("+Instance \(target) is unbound from \(instance.namespace)")
                    } else {
                        log("?Invalid instance id: \(target)")
                    }
                } else if let member = typeInfo[opcode] where member.isProperty {
                    // Update property
                    object.updateNativeProperty(opcode, withValue: body["$operand"] ?? NSNull())
                } else if let member = typeInfo[opcode] where member.isMethod {
                    // Invoke method
                    if let args = (body["$operand"] ?? []) as? [AnyObject] {
                        object.invokeNativeMethod(opcode, withArguments: args)
                    } // else malformatted operand
                } else {
                    log("?Invalid member name: \(opcode)")
                }
            } else if opcode == "+" {
                // Create instance
                let args = body["$operand"] as? [AnyObject]
                let namespace = "\(principal.namespace)[\(target)]"
                instances[target] = XWVBindingObject(namespace: namespace, channel: self, arguments: args)
                log("+Instance \(target) is bound to \(namespace)")
            } // else Unknown opcode
        } else if let obj = principal.plugin as? WKScriptMessageHandler {
            // Plugin claims for raw messages
            obj.userContentController(userContentController, didReceiveScriptMessage: message)
        } else {
            // discard unknown message
            log("-Unknown message: \(message.body)")
        }
    }

    private func generateStub(object: XWVBindingObject) -> String {
        func generateMethod(this: String, name: String, prebind: Bool) -> String {
            let stub = "XWVPlugin.invokeNative.bind(\(this), '\(name)')"
            return prebind ? "\(stub);" : "function(){return \(stub).apply(null, arguments);}"
        }

        var base = "null"
        var prebind = true
        if let member = typeInfo[""] {
            if member.isInitializer {
                base = "'\(member.type)'"
                prebind = false
            } else {
                base = generateMethod("arguments.callee", name: "\(member.type)", prebind: false)
            }
        }

        var stub = "(function(exports) {\n"
        for (name, member) in typeInfo {
            if member.isMethod && !name.isEmpty {
                let method = generateMethod(prebind ? "exports" : "this", name: "\(name)\(member.type)", prebind: prebind)
                stub += "exports.\(name) = \(method)\n"
            } else if member.isProperty {
                let value = object.serialize(object[name])
                stub += "XWVPlugin.defineProperty(exports, '\(name)', \(value), \(member.setter != nil));\n"
            }
        }
        stub += "})(XWVPlugin.createPlugin('\(name)', '\(object.namespace)', \(base)));\n\n"
        return stub
    }
}
