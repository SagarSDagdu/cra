import type { Id } from "./_generated/dataModel";
import type { MutationCtx, QueryCtx } from "./_generated/server";

export async function hashPassword(password: string, salt: string): Promise<string> {
  const data = new TextEncoder().encode(salt + password);
  const buf = await crypto.subtle.digest("SHA-256", data);
  return Array.from(new Uint8Array(buf)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

export function randomHex(bytes: number): string {
  const arr = new Uint8Array(bytes);
  crypto.getRandomValues(arr);
  return Array.from(arr).map((b) => b.toString(16).padStart(2, "0")).join("");
}

export function splitName(name?: string) {
  const trimmed = name?.trim();
  if (!trimmed) return { firstName: undefined, lastName: undefined };
  const parts = trimmed.split(/\s+/).filter(Boolean);
  if (parts.length === 1) return { firstName: parts[0], lastName: undefined };
  return { firstName: parts[0], lastName: parts.slice(1).join(" ") };
}

export function fullName(firstName?: string, lastName?: string) {
  const combined = `${firstName?.trim() ?? ""} ${lastName?.trim() ?? ""}`.trim();
  return combined || undefined;
}

export type PublicUser = {
  userId: Id<"users">;
  email: string;
  name?: string;
  firstName?: string;
  lastName?: string;
  profileImageUrl?: string;
  isAdmin: boolean;
  emailVerified: boolean;
  authProvider: string;
};

export function publicUser(user: any): PublicUser {
  const legacy = splitName(user.name);
  const firstName = user.firstName ?? legacy.firstName;
  const lastName = user.lastName ?? legacy.lastName;
  return {
    userId: user._id,
    email: user.email,
    name: fullName(firstName, lastName) ?? user.name,
    firstName,
    lastName,
    profileImageUrl: user.profileImageUrl,
    isAdmin: user.isAdmin ?? false,
    emailVerified: user.emailVerified ?? false,
    authProvider: user.authProvider ?? "email",
  };
}

export async function createSession(ctx: MutationCtx, userId: Id<"users">, device?: string) {
  const token = randomHex(32);
  const now = Date.now();
  await ctx.db.insert("sessions", { userId, token, device, createdAt: now, lastSeenAt: now });
  await ctx.db.patch(userId, { lastLoginAt: now });
  return token;
}

/** Resolve a session token to its user, or null. */
export async function userForToken(ctx: QueryCtx | MutationCtx, token: string) {
  if (!token) return null;
  const session = await ctx.db
    .query("sessions")
    .withIndex("by_token", (q) => q.eq("token", token))
    .first();
  if (!session) return null;
  const user = await ctx.db.get(session.userId);
  if (!user) return null;
  return { session, user };
}

export async function requireUser(ctx: QueryCtx | MutationCtx, token: string) {
  const found = await userForToken(ctx, token);
  if (!found) throw new Error("Not signed in.");
  return found;
}
