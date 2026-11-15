import { Backend, Metric, MetricKind, MetricUnit, SpanHandle, SpanKind, SpanStatus, TraceContext, Attribute, root_context, int_attribute } from std.telemetry;

var metric_total: i64 = 0;
var span_count: usize = 0;
var event_count: usize = 0;
var end_count: usize = 0;

fn add(context: usize, metric: Metric, value: i64): void {
    metric_total = metric_total + value;
}

fn start(context: usize, parent: TraceContext, timestamp: i64, name: string, kind: SpanKind, attributes: []const Attribute): SpanHandle {
    span_count = span_count + 1;
    return SpanHandle {
        id: span_count,
        context: TraceContext {
            trace_id: 7,
            span_id: span_count as u64,
            sampled: true
        }
    };
}

fn event(context: usize, handle: usize, timestamp: i64, name: string, attributes: []const Attribute): void {
    assert(attributes.len() == 1);
    assert(attributes[0].integer == 42);
    event_count = event_count + 1;
}

fn end(context: usize, handle: usize, timestamp: i64, status: SpanStatus): void {
    assert(status == SpanStatus.ok);
    end_count = end_count + 1;
}

fn main(): i32 {
    const backend = Backend {
        context: 0,
        metric_add: add,
        metric_set: add,
        span_start: start,
        span_event: event,
        span_end: end
    };
    const attributes: List<Attribute> = [int_attribute("step", 42)];
    backend.add(Metric {
        group: "compute",
        name: "runs",
        kind: MetricKind.counter,
        unit: MetricUnit.count
    }, 3);
    const scope = backend.start_span(root_context(), "compute.execution", SpanKind.internal, attributes.storage[..]);
    scope.event("compute.step", attributes.storage[..]);
    scope.end(SpanStatus.ok);
    assert(metric_total == 3);
    assert(span_count == 1);
    assert(event_count == 1);
    assert(end_count == 1);
    return 0;
}
