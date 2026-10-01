pub const Item = struct {
    price: f64,
    quantity: u32,
};

fn subtotal(items: []const Item) f64 {
    var amount: f64 = 0;
    for (items) |item| {
        const qty: f64 = @floatFromInt(item.quantity);
        amount += item.price * qty;
    }
    return amount;
}

pub fn total(items: []const Item, discount: f64) f64 {
    const amount = subtotal(items);
    return amount * (1 - discount);
}
