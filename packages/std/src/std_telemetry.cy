import { monotonic_ns } from std.time;

pub enum MetricKind: i32 {
    counter = 0,
    gauge
}
pub enum MetricUnit: i32 {
    count = 0,
    bytes,
    nanoseconds
}
pub enum SpanKind: i32 {
    internal = 0,
    server,
    client,
    producer,
    consumer
}
pub enum SpanStatus: i32 {
    unset = 0,
    ok,
    err
}

pub struct Metric {
    pub group: string;
    pub name: string;
    pub kind: MetricKind;
    pub unit: MetricUnit;
}

pub enum AttributeKind: i32 {
    boolean = 0,
    integer,
    float,
    text
}

pub struct Attribute {
    pub key: string;
    pub kind: AttributeKind;
    pub boolean: bool;
    pub integer: i64;
    pub float: f64;
    pub text: string;
}

pub fn bool_attribute(key: string, value: bool): Attribute {
    return Attribute {
        key: key,
        kind: AttributeKind.boolean,
        boolean: value,
        integer: 0,
        float: 0.0,
        text: ""
    };
}

pub fn int_attribute(key: string, value: i64): Attribute {
    return Attribute {
        key: key,
        kind: AttributeKind.integer,
        boolean: false,
        integer: value,
        float: 0.0,
        text: ""
    };
}

pub fn float_attribute(key: string, value: f64): Attribute {
    return Attribute {
        key: key,
        kind: AttributeKind.float,
        boolean: false,
        integer: 0,
        float: value,
        text: ""
    };
}

pub fn text_attribute(key: string, value: string): Attribute {
    return Attribute {
        key: key,
        kind: AttributeKind.text,
        boolean: false,
        integer: 0,
        float: 0.0,
        text: value
    };
}

pub struct TraceContext {
    pub trace_id: u64;
    pub span_id: u64;
    pub sampled: bool;
}

pub fn root_context(): TraceContext {
    return TraceContext {
        trace_id: 0,
        span_id: 0,
        sampled: true
    };
}

pub struct SpanHandle {
    pub id: usize;
    pub context: TraceContext;
}

// The host owns callback state and any copied records. Attribute slices are valid
// only during the callback. Use disabled() when no collector is installed.
pub struct Backend {
    pub context: usize;
    pub metric_add: fn (usize, Metric, i64): void;
    pub metric_set: fn (usize, Metric, i64): void;
    pub span_start: fn (usize, TraceContext, i64, string, SpanKind, []const Attribute): SpanHandle;
    pub span_event: fn (usize, usize, i64, string, []const Attribute): void;
    pub span_end: fn (usize, usize, i64, SpanStatus): void;

    pub fn add(self: Backend, metric: Metric, delta: i64): void {
        const callback = self.metric_add;
        callback(self.context, metric, delta);
    }

    pub fn set(self: Backend, metric: Metric, value: i64): void {
        const callback = self.metric_set;
        callback(self.context, metric, value);
    }

    pub fn start_span(self: Backend, parent: TraceContext, name: string, kind: SpanKind, attributes: []const Attribute): Scope {
        const callback = self.span_start;
        const handle = callback(self.context, parent, timestamp_ns(), name, kind, attributes);
        return Scope {
            backend: self,
            handle: handle
        };
    }
}

pub struct Scope {
    pub backend: Backend;
    pub handle: SpanHandle;

    pub fn event(self: Scope, name: string, attributes: []const Attribute): void {
        const callback = self.backend.span_event;
        callback(self.backend.context, self.handle.id, timestamp_ns(), name, attributes);
    }

    pub fn child(self: Scope, name: string, kind: SpanKind, attributes: []const Attribute): Scope {
        return self.backend.start_span(self.handle.context, name, kind, attributes);
    }

    pub fn end(self: Scope, status: SpanStatus): void {
        const callback = self.backend.span_end;
        callback(self.backend.context, self.handle.id, timestamp_ns(), status);
    }
}

fn timestamp_ns(): i64 {
    return monotonic_ns() catch (code) => 0;
}

fn discard_metric(context: usize, metric: Metric, value: i64): void {}
fn discard_start(context: usize, parent: TraceContext, timestamp: i64, name: string, kind: SpanKind, attributes: []const Attribute): SpanHandle {
    return SpanHandle {
        id: 0,
        context: parent
    };
}
fn discard_event(context: usize, handle: usize, timestamp: i64, name: string, attributes: []const Attribute): void {}
fn discard_end(context: usize, handle: usize, timestamp: i64, status: SpanStatus): void {}

pub fn disabled(): Backend {
    return Backend {
        context: 0,
        metric_add: discard_metric,
        metric_set: discard_metric,
        span_start: discard_start,
        span_event: discard_event,
        span_end: discard_end,
    };
}
