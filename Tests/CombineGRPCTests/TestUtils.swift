//
//  TestUtils.swift
//  CombineGRPCTests
//
//  Created by Vy-Shane Xie on 12/7/19.
//

import Foundation
import Combine
import GRPC
import NIO

let connectionTarget = ConnectionTarget.hostAndPort("localhost", 30120)

func makeTestServer(services: [CallHandlerProvider]) throws -> EventLoopGroup {  
  return try makeTestServer(services: services, eventLoopGroupSize: 1)
}

func makeTestServer(services: [CallHandlerProvider], eventLoopGroupSize: Int) throws -> EventLoopGroup {
  let eventLoopGroup = GRPCNIO.makeEventLoopGroup(loopCount: eventLoopGroupSize)
  let configuration = Server.Configuration(
    target: connectionTarget,
    eventLoopGroup: eventLoopGroup,
    serviceProviders: services
  )
  _ = try Server.start(configuration: configuration).wait()
  return eventLoopGroup
}

func makeTestClient<Client>(_ clientCreator: (ClientConnection, CallOptions) -> Client) -> Client
  where Client: GRPCServiceClient
{
  let eventLoopGroup = GRPCNIO.makeEventLoopGroup(loopCount: 1)
  let configuration = ClientConnection.Configuration(
    target: connectionTarget,
    eventLoopGroup: eventLoopGroup
  )
  let connection = ClientConnection(configuration: configuration)
  let callOptions = CallOptions(timeout: try! .milliseconds(100))
  return clientCreator(connection, callOptions)
}
