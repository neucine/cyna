import { queue_slots } from config;
import { Task } from model;

pub fn seed_queue(): [:]?Task {
    var slots = [:]?Task[
        Task {
            id: 5,
            owner: "ops",
            title: "api",
            estimate: 8,
            blocked: false
        },
        Task {
            id: 4,
            owner: "qa",
            title: "tests",
            estimate: 6,
            blocked: true
        },
        none,
        Task {
            id: 3,
            owner: "ops",
            title: "docs",
            estimate: 4,
            blocked: false
        },
        Task {
            id: 2,
            owner: "cli",
            title: "tool",
            estimate: 5,
            blocked: false
        },
    ];
    return slots;
}
