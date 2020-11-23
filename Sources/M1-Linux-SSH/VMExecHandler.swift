//
//  VMExecHandler.swift
//
//  Created by Jacopo Mangiavacchi on 11/21/20.
//  Copyright © 2020 Jacopo Mangiavacchi. All rights reserved.
//

import Dispatch
import Foundation
import NIO
import NIOFoundationCompat
import NIOSSH

enum SSHServerError: Error {
    case invalidCommand
    case invalidDataType
    case invalidChannelType
    case alreadyListening
    case notListening
}

final class VMExecHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    let queue = DispatchQueue(label: "background exec")
    var environment: [String: String] = [:]
    
    var inPipe: Pipe!
    var outPipe: Pipe!

    func handlerAdded(context: ChannelHandlerContext) {
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { error in
            print(error)

            context.fireErrorCaught(error)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        context.fireChannelInactive()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case _ as SSHChannelRequestEvent.ExecRequest:
            self.exec(channel: context.channel)

        case let event as SSHChannelRequestEvent.EnvironmentRequest:
            self.queue.sync {
                environment[event.name] = event.value
            }

        case _ as SSHChannelRequestEvent.ShellRequest:
            self.exec(channel: context.channel)

        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let data = self.unwrapInboundIn(data)

        guard case .byteBuffer(let bytes) = data.data else {
            fatalError("Unexpected read type")
        }

        guard case .channel = data.type else {
            context.fireErrorCaught(SSHServerError.invalidDataType)
            return
        }

        context.fireChannelRead(self.wrapInboundOut(bytes))
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let data = self.unwrapOutboundIn(data)
        context.write(self.wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(data))), promise: promise)
    }

    private func exec(channel: Channel) {
        self.queue.async {
            do {
                let (ours, theirs) = GlueHandler.matchedPair()
                try channel.pipeline.addHandler(ours).wait()

                _ = try NIOPipeBootstrap(group: channel.eventLoop)
                    .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                    .channelInitializer { pipeChannel in
                        pipeChannel.pipeline.addHandler(theirs)
                    }.withPipes(inputDescriptor: self.outPipe.fileHandleForReading.fileDescriptor, outputDescriptor: self.inPipe.fileHandleForWriting.fileDescriptor).wait()

                channel.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil)

            } catch {
                channel.close(promise: nil)
            }
        }
    }
}
