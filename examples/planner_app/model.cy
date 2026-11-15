pub enum PlannerError: i32 {
    missing_focus = 0,
    missing_owner,
    invalid_state,
}

pub struct Ticket {
    pub id: i32;
    pub owner: string;
    pub title: string;
    pub estimate: i32;

    pub fn priority(self: Ticket): i32 {
        return self.id + self.estimate + (self.title.len() as i32);
    }
}

impl Ticket: Clone {
    fn clone(self: &const Ticket): Ticket {
        return Ticket {
            id: self.id,
            owner: self.owner.clone(),
            title: self.title.clone(),
            estimate: self.estimate,
        };
    }
}
