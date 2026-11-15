import embedded.hal;

pub enum PinState {
    low,
    high,
}

pub protocol OutputPin {
    fn set_high(self: &Self): void ! hal.HalError;
    fn set_low(self: &Self): void ! hal.HalError;
    fn set_state(self: &Self, state: PinState): void ! hal.HalError;
}

pub protocol InputPin {
    fn is_high(self: &Self): bool ! hal.HalError;
    fn is_low(self: &Self): bool ! hal.HalError;
}

pub protocol StatefulOutputPin {
    fn is_set_high(self: &Self): bool ! hal.HalError;
    fn is_set_low(self: &Self): bool ! hal.HalError;
}

pub protocol ToggleOutputPin {
    fn toggle(self: &Self): void ! hal.HalError;
}
