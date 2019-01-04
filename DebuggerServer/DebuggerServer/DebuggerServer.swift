//
//  RemoteDebugging.swift
//  Recordings
//
//  Created by Chris Eidhof on 24.05.18.
//

import UIKit

extension UIView {
    func capture() -> UIImage? {
        let format = UIGraphicsImageRendererFormat()
        format.opaque = isOpaque
        let renderer = UIGraphicsImageRenderer(size: frame.size, format: format)
        return renderer.image { _ in
            drawHierarchy(in: frame, afterScreenUpdates: true)
        }
    }
}

struct DebugData<S: Encodable>: Encodable {
    var state: S
    var action: String
    var imageData: Data
}

final class BufferedWriter: NSObject, StreamDelegate {
    private let output: OutputStream
    private let queue = DispatchQueue(label: "remote debugger writer")
    private var buffer = Data()
    private let onEnd: (Result) -> ()
    
    enum Result {
        case eof
        case error(Error)
    }
    
    init(_ outputStream: OutputStream, onEnd: @escaping (Result) -> ()) {
        self.output = outputStream
        self.onEnd = onEnd
        super.init()
        CFWriteStreamSetDispatchQueue(outputStream, queue)
        outputStream.open()
        outputStream.delegate = self
    }
    
    func write(_ data: Data) {
        queue.async {
            self.buffer.append(data)
            self.resume()
        }
    }
    
    private func resume() {
        while output.hasSpaceAvailable && output.streamStatus == .open && !buffer.isEmpty {
            let data = buffer.prefix(1024)
            let bytesWritten = data.withUnsafeBytes { bytes in
                output.write(bytes, maxLength: data.count)
            }
            switch bytesWritten {
            case -1:
                output.close()
                onEnd(.error(output.streamError!))
            case 0:
                output.close()
                onEnd(.eof)
            case 1...:
                buffer.removeFirst(bytesWritten)
            default:
                fatalError()
            }
        }
    }
    
    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case .openCompleted:
            resume()
        case .hasSpaceAvailable:
            resume()
        case .errorOccurred:
            output.close()
            onEnd(.error(output.streamError!))
        case .endEncountered:
            output.close()
            onEnd(.eof)
        default:
            fatalError("Unknown event \(eventCode)")
            
        }
    }
}

public final class RemoteDebugger: NSObject, NetServiceBrowserDelegate {
    let browser = NetServiceBrowser()
    let queue = DispatchQueue(label: "remoteDebugger")
    var writer: BufferedWriter?
    
    public override init() {
        super.init()
        browser.delegate = self
        browser.searchForServices(ofType: "_debug._tcp", inDomain: "local")
    }
    
    public func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        var input: InputStream?
        var output: OutputStream?
        service.getInputStream(&input, outputStream: &output)
        CFReadStreamSetDispatchQueue(input, queue)
        guard let o = output else { return }
        writer = BufferedWriter(o) { [unowned self] result in
            print(result)
            self.writer = nil
        }
    }
    
    public func write<S: Encodable>(action: String, state: S, snapshot: UIView) throws {
        guard let w = writer else { return }
        
        let image = snapshot.capture()!
        let imageData = image.pngData()!
        let data = DebugData(state: state, action: action, imageData: imageData)
        let encoder = JSONEncoder()
        let json = try! encoder.encode(data)
        var encodedLength = Data(count: 4)
        encodedLength.withUnsafeMutableBytes { bytes in
            bytes.pointee = Int32(json.count)
        }
        w.write([206] + encodedLength + json)
    }
}
