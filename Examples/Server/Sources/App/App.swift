//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift OTel open source project
//
// Copyright (c) 2024 Moritz Lang and the Swift OTel project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Hummingbird
import Logging
import Metrics
import OTel
import OTLPGRPC
import Tracing
import ServiceLifecycle

@main
enum ServerMiddlewareExample {
    static func main() async throws {
        // Bootstrap the logging backend with the OTel metadata provider which includes span IDs in logging messages.
        LoggingSystem.bootstrap { label in
            var handler = StreamLogHandler.standardError(label: label, metadataProvider: .otel)
            handler.logLevel = .trace
            return handler
        }
        let logger = Logger(label: "example-logger")

        // Configure OTel resource detection to automatically apply helpful attributes to events.
        let environment = OTelEnvironment.detected()
        let resourceDetection = OTelResourceDetection(detectors: [
            OTelProcessResourceDetector(),
            OTelEnvironmentResourceDetector(environment: environment),
            .manual(OTelResource(attributes: ["service.name": "example_otel_server"])),
        ])
        let resource = await resourceDetection.resource(environment: environment, logLevel: .trace)

        // Bootstrap the metrics backend to export metrics periodically in OTLP/gRPC.
        let registry = OTelMetricRegistry()
        let metricsExporter = try OTLPGRPCMetricExporter(configuration: .init(environment: environment))
        let metrics = OTelPeriodicExportingMetricsReader(
            resource: resource,
            producer: registry,
            exporter: metricsExporter,
            configuration: .init(
                environment: environment,
                exportInterval: .seconds(5) // NOTE: This is overridden for the example; the default is 60 seconds.
            )
        )
        MetricsSystem.bootstrap(OTLPMetricsFactory(registry: registry))

        // Bootstrap the tracing backend to export traces periodically in OTLP/gRPC.
        let exporter = try OTLPGRPCSpanExporter(configuration: .init(environment: environment))
        let processor = OTelBatchSpanProcessor(exporter: exporter, configuration: .init(environment: environment))
        let tracer = OTelTracer(
            idGenerator: OTelRandomIDGenerator(),
            sampler: OTelConstantSampler(isOn: true),
            propagator: OTelW3CPropagator(),
            processor: processor,
            environment: environment,
            resource: resource
        )
        InstrumentationSystem.bootstrap(tracer)

        // Create an HTTP server with instrumentation middleware and a simple /hello endpoint, on 127.0.0.1:8080.
        let router = Router()
        router.middlewares.add(TracingMiddleware())
        router.middlewares.add(MetricsMiddleware())
        router.middlewares.add(LogRequestsMiddleware(.info))
        router.get("hello") { _, _ in
            logger.info("Received a request to /hello")
            return "hello"
        }
        let counterService = Counter()
        var app = Application(router: router)

        // Add the tracer lifecycle service to the HTTP server service group and start the application.
        app.addServices(metrics, tracer, counterService)
        try await app.runService()
    }
}

struct Counter: Service, CustomStringConvertible {
    let description = "Example"
    
    private let stream: AsyncStream<Int>
    private let continuation: AsyncStream<Int>.Continuation
    
    private let logger = Logger(label: "Counter")
    
    init() {
        (stream, continuation) = AsyncStream.makeStream()
    }
    
    func run() async {
        continuation.yield(0)
        
        for await value in stream.cancelOnGracefulShutdown() {
            let delay = Duration.seconds(.random(in: 0 ..< 1))
            
            do {
                try await withSpan("count") { span in
                    if value % 10 == 0 {
                        logger.error("Failed to count up, skipping value.", metadata: ["value": "\(value)"])
                        span.recordError(CounterError.failedIncrementing(value: value))
                        span.setStatus(.init(code: .error))
                        continuation.yield(value + 1)
                    } else {
                        span.attributes["value"] = value
                        logger.info("Counted up.", metadata: ["count": "\(value)"])
                        try await Task.sleep(for: delay)
                        continuation.yield(value + 1)
                    }
                }
            } catch {
                return
            }
        }
    }
}

enum CounterError: Error {
    case failedIncrementing(value: Int)
}
