import { defineSchema, defineTable } from "convex/server";
import { v } from "convex/values";

// Users follow the GhostWriter/Spook shape (email + salted SHA-256 password,
// optional Google identity). Sessions carry a random token so the native app
// never has to treat a user id as a credential.
export default defineSchema({
  users: defineTable({
    email: v.string(),
    passwordHash: v.string(),
    salt: v.string(),
    name: v.optional(v.string()),
    firstName: v.optional(v.string()),
    lastName: v.optional(v.string()),
    profileImageUrl: v.optional(v.string()),
    googleId: v.optional(v.string()),
    authProvider: v.optional(v.string()), // "email" | "google"
    emailVerified: v.optional(v.boolean()),
    isAdmin: v.optional(v.boolean()),
    onboardingCompleted: v.optional(v.boolean()),
    createdAt: v.number(),
    lastLoginAt: v.optional(v.number()),
  })
    .index("by_email", ["email"])
    .index("by_googleId", ["googleId"]),

  sessions: defineTable({
    userId: v.id("users"),
    token: v.string(),
    device: v.optional(v.string()),
    createdAt: v.number(),
    lastSeenAt: v.number(),
  })
    .index("by_token", ["token"])
    .index("by_user", ["userId"]),

  // App preferences synced across devices (auto-archive, search engine...).
  userSettings: defineTable({
    userId: v.id("users"),
    settings: v.any(),
    updatedAt: v.number(),
  }).index("by_user", ["userId"]),

  // Full sidebar backup (spaces, pinned tabs, folders, favorites) per device.
  sidebarBackups: defineTable({
    userId: v.id("users"),
    device: v.string(),
    document: v.any(),
    tabCount: v.number(),
    updatedAt: v.number(),
  }).index("by_user_device", ["userId", "device"]),
});
