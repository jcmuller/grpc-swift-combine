// Copyright 2019, Vy-Shane Xie
// Licensed under the Apache License, Version 2.0

import Combine
import CombineExt
import GRPC
import NIOHPACK
import SwiftProtobuf

/**
 A unary RPC client method generated by Swift gRPC.
 */
public typealias UnaryRPC<Request, Response> =
  (Request, CallOptions?) -> UnaryCall<Request, Response>
  where Request: Message, Response: Message

/**
 A server streaming RPC client method generated by Swift gRPC.
 */
public typealias ServerStreamingRPC<Request, Response> =
  (Request, CallOptions?, @escaping (Response) -> Void) -> ServerStreamingCall<Request, Response>
  where Request: Message, Response: Message

/**
 A client streaming RPC client method generated by Swift gRPC.
 */
public typealias ClientStreamingRPC<Request, Response> =
  (CallOptions?) -> ClientStreamingCall<Request, Response>
  where Request: Message, Response: Message

/**
 A bidirectional streaming RPC client method generated by Swift gRPC.
 */
public typealias BidirectionalStreamingRPC<Request, Response> =
  (CallOptions?, @escaping (Response) -> Void) -> BidirectionalStreamingCall<Request, Response>
  where Request: Message, Response: Message

/**
 Executes gRPC calls.
 
 Can be configured with `CallOptions` to use when making RPC calls, as well as a `RetryPolicy` for automatic retries of failed RPC calls.
 */
@available(OSX 10.15, iOS 13, tvOS 13, *)
public struct GRPCExecutor {
  
  private let retryPolicy: RetryPolicy
  private let callOptions: CurrentValueSubject<CallOptions, Never>
  private var retainedCancellables: Set<AnyCancellable> = []
  
  /**
   Initialize `GRPCExecutor` with a stream of `CallOptions` and a `RetryPolicy`.
   
   - Parameters:
     - callOptions: A publisher of `CallOptions`. The latest `CallOptions` received will be used when making a gRPC call.
       Defaults to a stream with just one default `CallOptions()` value.
     - retry: `RetryPolicy` to use if a gRPC call fails. Defaults to `RetryPolicy.never`.
   */
  public init(callOptions: AnyPublisher<CallOptions, Never> = Just(CallOptions()).eraseToAnyPublisher(),
       retry: RetryPolicy = .never) {
    self.retryPolicy = retry

    let subject = CurrentValueSubject<CallOptions, Never>(CallOptions())
    callOptions.sink(receiveValue: { subject.send($0) }).store(in: &retainedCancellables)
    self.callOptions = subject
  }
  
  // MARK:- Unary
  
  /**
   Make a unary gRPC call.
   
   - Parameters:
     - rpc: The unary RPC to call, a method that is generated by Swift gRPC.
   
   - Returns: A function that takes a request and returns a publisher that will either publish one `Response` or fail with an `RPCError` error.
   
   In the following example the `sayHello` client method is generated by Swift gRPC.
   
   ```
   let grpc = GRPCExecutor()
   let helloResponse = grpc.call(client.sayHello)(HelloRequest())
   ```
   
   `call` is curried. You can preconfigure a unary call:
   
   ```
   let grpc = GRPCExecutor()
   let sayHello = grpc.call(client.sayHello)
   let helloResponse = sayHello(HelloRequest())
   ```
   */
  public func call<Request, Response>(_ rpc: @escaping UnaryRPC<Request, Response>)
    -> (Request)
    -> AnyPublisher<Response, RPCError>
    where Request: Message, Response: Message
  {
    { request in
      self.executeWithRetry(policy: self.retryPolicy, { currentCallOptions in
        currentCallOptions
          .flatMap { callOptions in
            Future<Response, RPCError> { promise in
              let call = rpc(request, callOptions)
              call.response.whenSuccess { promise(.success($0)) }
              
              // Trailing metadata will be available before status.
              var trailingMetadata: HPACKHeaders?
              call.trailingMetadata.whenSuccess { trailingMetadata = $0 }

              // The status EventLoopFuture succeeds when RPC fails.
              call.status.whenSuccess {
                promise(.failure(
                  RPCError(status: $0, trailingMetadata: trailingMetadata)
                ))
              }
            }
          }
          .eraseToAnyPublisher()
      })
    }
  }
  
  // MARK: Server Streaming
  
  /**
   Make a server streaming gRPC call.
   
   - Parameters:
     - rpc: The server streaming RPC to call, a method that is generated by Swift gRPC.
   
   - Returns: A function that takes a request and returns a publisher that publishes a stream of `Response`s.
     The response publisher may fail with an `RPCError` error.
   
   `call` is curried.
   
   Example:
   
   ```
   let grpc = GRPCExecutor()
   let responses: AnyPublisher<Post, RPCError> = grpc.call(client.listPosts)(listPostsRequest)
   ```
   */
  public func call<Request, Response>(_ rpc: @escaping ServerStreamingRPC<Request, Response>)
    -> (Request)
    -> AnyPublisher<Response, RPCError>
    where Request: Message, Response: Message
  {
    { request in
      self.executeWithRetry(policy: self.retryPolicy, { currentCallOptions in
        currentCallOptions
          .flatMap { callOptions in
            AnyPublisher<Response, RPCError>.create { subscriber in
              let call = rpc(request, callOptions, subscriber.send)
              sendCompletion(status: call.status, trailingMetadata: call.trailingMetadata, toSubscriber: subscriber)

              return AnyCancellable {
                call.cancel(promise: nil)
              }
            }
          }
          .eraseToAnyPublisher()
      })
    }
  }
  
  // MARK: Client Streaming
  
  /**
   Make a client streaming gRPC call.
   
   - Parameters:
     - rpc: The client streaming RPC to call, a method that is generated by Swift gRPC.
   
   - Returns: A function that takes a stream of requests and returns a publisher that publishes either a `Response`
     or fails with an `RPCError` error.
   
   `call` is curried.
   */
  public func call<Request, Response>(_ rpc: @escaping ClientStreamingRPC<Request, Response>)
    -> (AnyPublisher<Request, Error>)
    -> AnyPublisher<Response, RPCError>
    where Request: Message, Response: Message
  {
    { requests in
      self.executeWithRetry(policy: self.retryPolicy, { currentCallOptions in
        currentCallOptions
          .flatMap { callOptions in
            AnyPublisher<Response, RPCError>.create { subscriber in
              let call = rpc(callOptions)
              
              // TODO: Can we avoid .sink() here in order to support backpressure?
              let requestsCancellable = requests.sink(
                receiveCompletion: { switch $0 {
                  case .finished: _ = call.sendEnd()
                  case .failure: call.cancel(promise: nil)
                }},
                receiveValue: { _ = call.sendMessage($0) }
              )
              call.response.whenSuccess { subscriber.send($0) }
              sendCompletion(status: call.status, trailingMetadata: call.trailingMetadata, toSubscriber: subscriber)

              return AnyCancellable {
                call.cancel(promise: nil)
                requestsCancellable.cancel()
              }
            }
        }
        .eraseToAnyPublisher()
      })
    }
  }
  
  // MARK: Bidirectional Streaming
  
  /**
   Make a bidirectional streaming gRPC call.
   
   - Parameters:
     - rpc: The bidirectional streaming RPC to call, a method that is generated by Swift gRPC.
   
   - Returns: A function that takes a stream of requests and returns a publisher that publishes a stream of `Response`s.
     The response publisher may fail with an `RPCError` error.
   
   `call` is curried.
   */
  public func call<Request, Response>(_ rpc: @escaping BidirectionalStreamingRPC<Request, Response>)
    -> (AnyPublisher<Request, Error>)
    -> AnyPublisher<Response, RPCError>
    where Request: Message, Response: Message
  {
    { requests in
      self.executeWithRetry(policy: self.retryPolicy, { currentCallOptions in
        currentCallOptions
          .flatMap { callOptions in
            AnyPublisher<Response, RPCError>.create { subscriber in
              let call = rpc(callOptions, subscriber.send)
              
              // TODO: Can we avoid .sink() here in order to support backpressure?
              let requestsCancellable = requests.sink(
                receiveCompletion: { switch $0 {
                  case .finished: _ = call.sendEnd()
                  case .failure: call.cancel(promise: nil)
                }},
                receiveValue: {
                  _ = call.sendMessage($0)
                }
              )
              sendCompletion(status: call.status, trailingMetadata: call.trailingMetadata, toSubscriber: subscriber)
              
              return AnyCancellable {
                call.cancel(promise: nil)
                requestsCancellable.cancel()
              }
            }
          }
          .eraseToAnyPublisher()
      })
    }
  }
  
  // MARK: -
  
  private func executeWithRetry<T>(
    policy: RetryPolicy,
    _ call: @escaping (AnyPublisher<CallOptions, RPCError>) -> AnyPublisher<T, RPCError>
  ) -> AnyPublisher<T, RPCError> {
    switch policy {
    case .never:
      return call(currentCallOptions())
      
    case .failedCall(let maxRetries, let shouldRetry, let delayUntilNext, let didGiveUp):
      precondition(maxRetries >= 1, "RetryPolicy.failedCall upTo parameter should be at least 1")
      var retryCount = 0

      func attemptCall() -> AnyPublisher<T, RPCError> {
        call(currentCallOptions())
          .catch { error -> AnyPublisher<T, RPCError> in
            if shouldRetry(error) && retryCount < maxRetries {
              retryCount += 1
              return delayUntilNext(retryCount, error)
                .setFailureType(to: RPCError.self)
                .flatMap { _ in attemptCall() }
                .eraseToAnyPublisher()
            }
            if shouldRetry(error) && retryCount == maxRetries {
              didGiveUp()
            }
            return Fail(error: error).eraseToAnyPublisher()
          }
          .map { response in
            // Reset retry count if we successfully receive a value.
            retryCount = 0
            return response
          }
          .eraseToAnyPublisher()
      }
      
      return attemptCall()
    }
  }
  
  private func currentCallOptions() -> AnyPublisher<CallOptions, RPCError> {
    self.callOptions
      .output(at: 0)
      .setFailureType(to: RPCError.self)
      .eraseToAnyPublisher()
  }
}
