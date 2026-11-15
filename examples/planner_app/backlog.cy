import { slot_count } from config;
import { Ticket } from model;

pub fn seed(): [:]?Ticket {
    var slots = [:]?Ticket[
        Ticket {
            id: 12,
            owner: "ops",
            title: "api",
            estimate: 8
        },
        Ticket {
            id: 7,
            owner: "cli",
            title: "cli",
            estimate: 6
        },
        none,
        Ticket {
            id: 5,
            owner: "ops",
            title: "docs",
            estimate: 4
        },
    ];
    return slots;
}
