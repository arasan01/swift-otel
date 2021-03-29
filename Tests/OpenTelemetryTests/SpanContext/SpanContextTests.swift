//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift OpenTelemetry open source project
//
// Copyright (c) 2021 Moritz Lang and the Swift OpenTelemetry project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import CoreBaggage
@testable import OpenTelemetry
import XCTest

final class SpanContextTests: XCTestCase {
    func test_storedInBaggage() {
        let spanContext = OTel.SpanContext(
            traceID: OTel.TraceID(bytes: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1)),
            spanID: OTel.SpanID(bytes: (0, 0, 0, 0, 0, 0, 0, 2)),
            parentSpanID: OTel.SpanID(bytes: (0, 0, 0, 0, 0, 0, 0, 1)),
            traceFlags: .sampled,
            traceState: OTel.TraceState()
        )

        var baggage = Baggage.topLevel
        XCTAssertNil(baggage.spanContext)

        baggage.spanContext = spanContext
        XCTAssertEqual(baggage.spanContext, spanContext)

        baggage.spanContext = nil
        XCTAssertNil(baggage.spanContext)
    }
}
