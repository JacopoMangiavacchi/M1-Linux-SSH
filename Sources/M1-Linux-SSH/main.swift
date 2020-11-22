//
//  main.swift
//
//  Created by Jacopo Mangiavacchi on 11/21/20.
//  Copyright © 2020 Jacopo Mangiavacchi. All rights reserved.
//

import Crypto
import Dispatch
import NIO
import NIOSSH
import ArgumentParser

struct VMService: ParsableCommand {
    @Argument(help: "Path to the Linux ISO file.")
    var linuxPath: String

    @Option(help: "IP Address.")
    var ip: String = "0.0.0.0"

    @Option(help: "Port.")
    var port: Int = 2222

    @Option(help: "SSH Username.")
    var username: String?

    @Option(help: "SSH Password.")
    var password: String?


    final class ErrorHandler: ChannelInboundHandler {
        typealias InboundIn = Any

        func errorCaught(context: ChannelHandlerContext, error: Error) {
            print("Error in pipeline: \(error)")
            context.close(promise: nil)
        }
    }

    final class HardcodedPasswordDelegate: NIOSSHServerUserAuthenticationDelegate {
        let username: String?
        let password: String?

        init(username: String?, password: String?) {
            self.username = username
            self.password = password
        }

        var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods {
            .password
        }

        func requestReceived(request: NIOSSHUserAuthenticationRequest, responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>) {
            responsePromise.succeed(.success)

            if let username = username {
                guard request.username == username else {
                    print("wrong username")
                    responsePromise.succeed(.failure)
                    return
                }
            }

            if let password = password {
                guard case .password(let passwordRequest) = request.request, passwordRequest.password == password else {
                    print("wrong password")
                    responsePromise.succeed(.failure)
                    return
                }
            }

            responsePromise.succeed(.success)
        }
    }

    func sshChildChannelInitializer(_ channel: Channel, _ channelType: SSHChannelType) -> EventLoopFuture<Void> {
        switch channelType {
        case .session:
            return channel.pipeline.addHandler(VMExecHandler())
        case .directTCPIP(let target):
            let (ours, theirs) = GlueHandler.matchedPair()

            return channel.pipeline.addHandlers([DataToBufferCodec(), ours]).flatMap {
                createOutboundConnection(targetHost: target.targetHost, targetPort: target.targetPort, loop: channel.eventLoop)
            }.flatMap { targetChannel in
                targetChannel.pipeline.addHandler(theirs)
            }
        case .forwardedTCPIP:
            return channel.eventLoop.makeFailedFuture(SSHServerError.invalidChannelType)
        }
    }

    func run() throws {
        print("\(username) \(password)")

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

        defer {
            try! group.syncShutdownGracefully()
        }

        // We need a host key. For now, generate it dynamically.
        let hostKey = NIOSSHPrivateKey(ed25519Key: .init())

        let bootstrap = ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                channel.pipeline.addHandlers([NIOSSHHandler(role: .server(.init(hostKeys: [hostKey], 
                                                                                userAuthDelegate: HardcodedPasswordDelegate(username: username, password: password), 
                                                                                globalRequestDelegate: RemotePortForwarderGlobalRequestDelegate())), 
                                                            allocator: channel.allocator, 
                                                            inboundChildChannelInitializer: sshChildChannelInitializer(_:_:)), 
                                            ErrorHandler()])
            }
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)

        print("start on \(ip) port \(port)")
        let channel = try bootstrap.bind(host: ip, port: port).wait()

        // Run forever
        try channel.closeFuture.wait()

        print("stop!")
    }
}

VMService.main()
