// Copyright 2019, Vy-Shane Xie
// Licensed under the Apache License, Version 2.0

import Combine
import GRPC
import NIO
import Foundation
@testable import CombineGRPC

@available(OSX 10.15, *)
class ClientStreamingTestsService: ClientStreamingScenariosProvider {

  // Echo back the last request message
  func clientStreamOk(context: UnaryResponseCallContext<EchoResponse>)
    -> EventLoopFuture<(StreamEvent<EchoRequest>) -> Void>
  {
    return handle(context) { requests in
      requests
        .last()
        .map { request in
          EchoResponse.with { $0.message = request.message }
        }
        .mapError { _ in .processingError }
        .eraseToAnyPublisher()
    }
  }

  func clientStreamFailedPrecondition(context: UnaryResponseCallContext<Empty>)
    -> EventLoopFuture<(StreamEvent<EchoRequest>) -> Void>
  {
    // TODO
    return context.eventLoop.makeFailedFuture(GRPCStatus(code: .unimplemented, message: "TODO"))
  }

  func clientStreamNoResponse(context: UnaryResponseCallContext<Empty>)
    -> EventLoopFuture<(StreamEvent<EchoRequest>) -> Void>
  {
    // TODO
    return context.eventLoop.makeFailedFuture(GRPCStatus(code: .unimplemented, message: "TODO"))
  }
}
