/// Interpolates the ground-contact Y from two simulation positions, adding the contact point's offset from that origin.
pub fn interpolatedFeetBottom(previous_y: f32, current_y: f32, alpha: f32, contact_offset: f32) f32 {
    return previous_y + (current_y - previous_y) * alpha + contact_offset;
}
