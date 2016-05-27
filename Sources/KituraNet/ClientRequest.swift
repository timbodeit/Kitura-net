/**
 * Copyright IBM Corporation 2016
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 **/

import KituraSys
import CCurl
import Socket

import Foundation

// MARK: ClientRequest

public class ClientRequest: SocketWriter {

    ///
    /// Internal lock to the request
    ///
    static private var lock = 0

    
    public var headers = [String: String]()

    // MARK: -- Private
    
    ///
    /// URL used for the request
    ///
    private var url: String
    
    /// 
    /// HTTP method (GET, POST, PUT, DELETE) for the request
    ///
    private var method: String = "get"
    
    ///
    /// Username if using Basic Auth 
    ///
    private var userName: String?
    
    /// 
    /// Password if using Basic Auth 
    ///
    private var password: String?

    ///
    /// Maximum number of redirects before failure
    ///
    private var maxRedirects = 10
    
    /// 
    /// ???
    ///
    private var handle: UnsafeMutablePointer<Void>?
    
    /// 
    /// List of header information
    ///
    private var headersList: UnsafeMutablePointer<curl_slist>?
    
    ///
    /// BufferList to store bytes to be written
    ///
    private var writeBuffers = BufferList()

    ///
    /// Response instance for communicating with client
    ///
    private var response = ClientResponse()
    
    
    private var callback: ClientRequestCallback
    
    private var disableSSLVerification = false

    ///
    /// Initializes a ClientRequest instance
    ///
    /// - Parameter url: url for the request 
    /// - Parameter callback:
    ///
    /// - Returns: a ClientRequest instance 
    ///
    init(url: String, callback: ClientRequestCallback) {
        
        self.url = url
        self.callback = callback
        
    }

    ///
    /// Initializes a ClientRequest instance
    ///
    /// - Parameter options: a list of options describing the request
    /// - Parameter callback:
    ///
    /// - Returns: a ClientRequest instance
    ///
    init(options: [ClientRequestOptions], callback: ClientRequestCallback) {

        self.callback = callback

        var theSchema = "http://"
        var hostName = "localhost"
        var path = "/"
        var port: Int16? = nil

        for option in options  {
            switch(option) {

                case .method(let method):
                    self.method = method
                case .schema(let schema):
                    theSchema = schema
                case .hostname(let host):
                    hostName = host
                case .port(let thePort):
                    port = thePort
                case .path(let thePath):
                    path = thePath
                case .headers(let headers):
                    for (key, value) in headers {
                        self.headers[key] = value
                    }
                case .username(let userName):
                    self.userName = userName
                case .password(let password):
                    self.password = password
                case .maxRedirects(let maxRedirects):
                    self.maxRedirects = maxRedirects
                case .disableSSLVerification:
                    self.disableSSLVerification = true
            }
        }

        // Adding support for Basic HTTP authentication
        let user = self.userName ?? ""
        let pwd = self.password ?? ""
        var authenticationClause = ""
        if (!user.isEmpty && !pwd.isEmpty) {
          authenticationClause = "\(user):\(pwd)@"
        }

        var portClause = ""
        if  let port = port  {
            portClause = ":\(String(port))"
        }

        url = "\(theSchema)\(authenticationClause)\(hostName)\(portClause)\(path)"

    }

    ///
    /// Instance destruction
    ///
    deinit {

        if  let handle = handle  {
            curl_easy_cleanup(handle)
        }

        if  headersList != nil  {
            curl_slist_free_all(headersList)
        }

    }

    ///
    /// Writes a string to the response
    ///
    /// - Parameter str: String to be written
    ///
    public func write(from string: String) {
        
        if  let data = StringUtils.toUtf8String(string)  {
            write(from: data)
        }
        
    }

    ///
    /// Writes data to the response
    ///
    /// - Parameter data: NSData to be written
    ///
    public func write(from data: NSData) {
        
        writeBuffers.append(data: data)
        
    }

    ///
    /// End servicing the request, send response back
    ///
    /// - Parameter data: string to send before ending
    ///
    public func end(_ data: String) {
        
        write(from: data)
        end()
        
    }

    ///
    /// End servicing the request, send response back
    ///
    /// - Parameter data: data to send before ending
    ///
    public func end(_ data: NSData) {
        
        write(from: data)
        end()
        
    }

    ///
    /// End servicing the request, send response back
    ///
    public func end() {
        
        // Be sure that a lock is obtained before this can be executed
        SysUtils.doOnce(&ClientRequest.lock) {
            
            curl_global_init(Int(CURL_GLOBAL_SSL))
            
        }

        var callCallback = true
        let urlBuf = StringUtils.toNullTerminatedUtf8String(url)
        
        if  let _ = urlBuf {
            
            prepareHandle(urlBuf!)

            let invoker = CurlInvoker(handle: handle!, maxRedirects: maxRedirects)
            invoker.delegate = self

            var code = invoker.invoke()
            if  code == CURLE_OK  {
                code = curlHelperGetInfoLong(handle!, CURLINFO_RESPONSE_CODE, &response.status)
                if  code == CURLE_OK  {
                    response.parse() {status in
                        switch(status) {
                            case .success:
                                self.callback(response: self.response)
                                callCallback = false

                            default:
                                print("ClientRequest error. Failed to parse response. status=\(status)")
                        }
                    }
                }
            }
            else {
                
                print("ClientRequest Error. CURL Return code=\(code)")
                
            }
        }
        
        if  callCallback  {
            callback(response: nil)
        }
        
    }

    ///
    /// Prepare the handle 
    ///
    /// Parameter urlBuf: ???
    ///
    private func prepareHandle(_ urlBuf: NSData) {
        
        handle = curl_easy_init()
        // HTTP parser does the decoding
        curlHelperSetOptInt(handle!, CURLOPT_HTTP_TRANSFER_DECODING, 0)
        curlHelperSetOptString(handle!, CURLOPT_URL, UnsafeMutablePointer<Int8>(urlBuf.bytes))
        if disableSSLVerification {
            curlHelperSetOptInt(handle!, CURLOPT_SSL_VERIFYHOST, 0)
            curlHelperSetOptInt(handle!, CURLOPT_SSL_VERIFYPEER, 0)
        }
        setMethod()
        let count = writeBuffers.count
        if  count != 0  {
            curlHelperSetOptInt(handle!, CURLOPT_POSTFIELDSIZE, count)
        }
        setupHeaders()
        let emptyCstring = StringUtils.toNullTerminatedUtf8String("")!
        curlHelperSetOptString(handle!, CURLOPT_COOKIEFILE, UnsafeMutablePointer<Int8>(emptyCstring.bytes))

        // To see the messages sent by libCurl, uncomment the next line of code
        //curlHelperSetOptInt(handle, CURLOPT_VERBOSE, 1)
    }

    ///
    /// Sets the HTTP method in libCurl to the one specified in method
    ///
    private func setMethod() {

        let methodUpperCase = method.uppercased()
        switch(methodUpperCase) {
            case "GET":
                curlHelperSetOptBool(handle!, CURLOPT_HTTPGET, CURL_TRUE)
            case "POST":
                curlHelperSetOptBool(handle!, CURLOPT_POST, CURL_TRUE)
            case "PUT":
                curlHelperSetOptBool(handle!, CURLOPT_PUT, CURL_TRUE)
            case "HEAD":
                curlHelperSetOptBool(handle!, CURLOPT_NOBODY, CURL_TRUE)
            default:
                let methodCstring = StringUtils.toNullTerminatedUtf8String(methodUpperCase)!
                curlHelperSetOptString(handle!, CURLOPT_CUSTOMREQUEST, UnsafeMutablePointer<Int8>(methodCstring.bytes))
        }

    }

    ///
    /// Sets the headers in libCurl to the ones in headers
    ///
    private func setupHeaders() {

        for (headerKey, headerValue) in headers {
            let headerString = StringUtils.toNullTerminatedUtf8String("\(headerKey): \(headerValue)")
            if  let headerString = headerString  {
                headersList = curl_slist_append(headersList, UnsafeMutablePointer<Int8>(headerString.bytes))
            }
        }
        curlHelperSetOptHeaders(handle!, headersList)
        
    }

}

// MARK: CurlInvokerDelegate extension
extension ClientRequest: CurlInvokerDelegate {
    
    ///
    ///
    private func curlWriteCallback(_ buf: UnsafeMutablePointer<Int8>, size: Int) -> Int {
        
        response.responseBuffers.append(bytes: UnsafePointer<UInt8>(buf), length: size)
        return size
        
    }

    private func curlReadCallback(_ buf: UnsafeMutablePointer<Int8>, size: Int) -> Int {
        
        let count = writeBuffers.fill(buffer: UnsafeMutablePointer<UInt8>(buf), length: size)
        return count
        
    }

    private func prepareForRedirect() {
        
        response.responseBuffers.reset()
        writeBuffers.rewind()
        
    }
}

///
/// Client request option values
///
public enum ClientRequestOptions {
    
    case method(String), schema(String), hostname(String), port(Int16), path(String),
    headers([String: String]), username(String), password(String), maxRedirects(Int), disableSSLVerification
    
}

/// 
/// Response callback closure
///
public typealias ClientRequestCallback = (response: ClientResponse?) -> Void

/// 
/// Helper class for invoking commands through libCurl
///
private class CurlInvoker {
    
    ///
    /// Pointer to the libCurl handle 
    ///
    private var handle: UnsafeMutablePointer<Void>
    
    ///
    /// Delegate that can have a read or write callback
    ///
    private weak var delegate: CurlInvokerDelegate?
    
    ///
    /// Maximum number of redirects 
    ///
    private let maxRedirects: Int

    ///
    /// Initializes a new CurlInvoker instance 
    ///
    private init(handle: UnsafeMutablePointer<Void>, maxRedirects: Int) {
        
        self.handle = handle
        self.maxRedirects = maxRedirects
        
    }

    ///
    /// Run the HTTP method through the libCurl library
    ///
    /// - Returns: a status code for the success of the operation
    ///
    private func invoke() -> CURLcode {

        var rc: CURLcode = CURLE_FAILED_INIT
        if delegate == nil {
            return rc
        }

        withUnsafeMutablePointer(&delegate) {ptr in
            self.prepareHandle(ptr)

            var redirected = false
            var redirectCount = 0
            repeat {
                rc = curl_easy_perform(handle)

                if  rc == CURLE_OK  {
                    var redirectUrl: UnsafeMutablePointer<Int8>? = nil
                    let infoRc = curlHelperGetInfoCString(handle, CURLINFO_REDIRECT_URL, &redirectUrl)
                    if  infoRc == CURLE_OK {
                        if  redirectUrl != nil  {
                            curlHelperSetOptString(handle, CURLOPT_URL, redirectUrl)
                            redirected = true
                            delegate?.prepareForRedirect()
                            redirectCount+=1
                        }
                        else {
                            redirected = false
                        }
                    }
                }

            } while  rc == CURLE_OK  &&  redirected  &&  redirectCount < maxRedirects
        }

        return rc
    }

    ///
    /// Prepare the handle
    ///
    /// - Parameter ptr: pointer to the CurlInvokerDelegate
    ///
    private func prepareHandle(_ ptr: UnsafeMutablePointer<CurlInvokerDelegate?>) {

        curlHelperSetOptReadFunc(handle, ptr) { (buf: UnsafeMutablePointer<Int8>?, size: Int, nMemb: Int, privateData: UnsafeMutablePointer<Void>?) -> Int in

                let p = UnsafePointer<CurlInvokerDelegate?>(privateData)
                return (p?.pointee?.curlReadCallback(buf!, size: size*nMemb))!
        }

        curlHelperSetOptWriteFunc(handle, ptr) { (buf: UnsafeMutablePointer<Int8>?, size: Int, nMemb: Int, privateData: UnsafeMutablePointer<Void>?) -> Int in

                let p = UnsafePointer<CurlInvokerDelegate?>(privateData)
                return (p?.pointee?.curlWriteCallback(buf!, size: size*nMemb))!
        }
    }
    
}

///
/// Delegate protocol for objects operated by CurlInvoker
///
private protocol CurlInvokerDelegate: class {
    
    func curlWriteCallback(_ buf: UnsafeMutablePointer<Int8>, size: Int) -> Int
    func curlReadCallback(_ buf: UnsafeMutablePointer<Int8>, size: Int) -> Int
    func prepareForRedirect()
    
}
