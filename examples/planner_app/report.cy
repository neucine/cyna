import { release_bonus } from config;
import { PlannerError, Ticket } from model;

pub fn build_registry(tickets: List<Ticket>): i32 ! PlannerError {
    var owners: Set<string> = set<string>();
    var points: Map<string, i32> = map<string, i32>();

    for ticket in tickets {
        owners.add(ticket.owner);
        if points.contains(ticket.owner) {
            points[ticket.owner] = points[ticket.owner] + ticket.priority();
        } else {
            points[ticket.owner] = ticket.priority();
        }
    }

    if not owners.contains("ops") {
        throw PlannerError.missing_owner;
    }

    var total: i32 = 0;
    var owners_list = points.keys();
    for owner in owners_list {
        if owner == "ops" {
            total = total + release_bonus;
        }
    }

    var point_values = points.values();
    for value in point_values {
        total = total + value;
    }

    return total;
}
