export function seedDefaults() {
  return {
    accounts: [
      accountSeed("现金", "cash", 0, 0),
      accountSeed("支付宝余额", "wallet", 0, 1),
      accountSeed("余利宝", "wallet", 0, 2),
      accountSeed("余额宝", "wallet", 0, 3),
      accountSeed("信用卡", "credit", 0, 4),
    ],
    categories: [
      categorySeed("工资", "income", 0),
      categorySeed("生活费", "expense", 1),
      categorySeed("房贷", "expense", 2),
      categorySeed("社保", "expense", 3),
      categorySeed("购物", "expense", 4),
      categorySeed("余额调整", "adjustment", 5),
      categorySeed("账户转账", "transfer", 6),
    ],
  };
}

function accountSeed(name, kind, openingBalance, sortOrder) {
  return {
    id: crypto.randomUUID(),
    name,
    kind,
    opening_balance: openingBalance,
    currency: "JPY",
    sort_order: sortOrder,
    created_at: new Date().toISOString(),
  };
}

function categorySeed(name, kind, sortOrder) {
  return {
    id: crypto.randomUUID(),
    name,
    kind,
    sort_order: sortOrder,
    created_at: new Date().toISOString(),
  };
}
