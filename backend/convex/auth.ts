import { v } from "convex/values";
import { internal } from "./_generated/api";
import type { Id } from "./_generated/dataModel";
import { action, internalMutation, internalQuery, mutation, query } from "./_generated/server";
import { createSession, fullName, hashPassword, publicUser, randomHex, splitName, userForToken } from "./lib";

// ─── Email + password ───────────────────────────────────────────────

export const signUp = mutation({
  args: { email: v.string(), password: v.string(), name: v.optional(v.string()), device: v.optional(v.string()) },
  handler: async (ctx, { email, password, name, device }) => {
    const normalizedEmail = email.toLowerCase().trim();
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(normalizedEmail)) throw new Error("Enter a valid email address.");
    const existing = await ctx.db.query("users").withIndex("by_email", (q) => q.eq("email", normalizedEmail)).first();
    if (existing) throw new Error("An account with this email already exists.");
    if (password.length < 6) throw new Error("Password must be at least 6 characters.");
    const salt = randomHex(16);
    const passwordHash = await hashPassword(password, salt);
    const parsed = splitName(name);
    const now = Date.now();
    const userId = await ctx.db.insert("users", {
      email: normalizedEmail,
      passwordHash,
      salt,
      name: fullName(parsed.firstName, parsed.lastName),
      firstName: parsed.firstName,
      lastName: parsed.lastName,
      authProvider: "email",
      emailVerified: false,
      createdAt: now,
      lastLoginAt: now,
    });
    const token = await createSession(ctx, userId, device);
    const user = await ctx.db.get(userId);
    return { token, user: publicUser(user) };
  },
});

export const login = mutation({
  args: { email: v.string(), password: v.string(), device: v.optional(v.string()) },
  handler: async (ctx, { email, password, device }) => {
    const normalizedEmail = email.toLowerCase().trim();
    const user = await ctx.db.query("users").withIndex("by_email", (q) => q.eq("email", normalizedEmail)).first();
    if (!user || !user.passwordHash) throw new Error("Invalid email or password.");
    const hash = await hashPassword(password, user.salt);
    if (hash !== user.passwordHash) throw new Error("Invalid email or password.");
    const token = await createSession(ctx, user._id, device);
    return { token, user: publicUser(user) };
  },
});

export const validate = query({
  args: { token: v.string() },
  handler: async (ctx, { token }) => {
    const found = await userForToken(ctx, token);
    return found ? publicUser(found.user) : null;
  },
});

export const touch = mutation({
  args: { token: v.string() },
  handler: async (ctx, { token }) => {
    const found = await userForToken(ctx, token);
    if (found) await ctx.db.patch(found.session._id, { lastSeenAt: Date.now() });
    return found ? publicUser(found.user) : null;
  },
});

export const logout = mutation({
  args: { token: v.string() },
  handler: async (ctx, { token }) => {
    const found = await userForToken(ctx, token);
    if (found) await ctx.db.delete(found.session._id);
    return null;
  },
});

export const checkEmail = query({
  args: { email: v.string() },
  handler: async (ctx, { email }) => {
    const user = await ctx.db.query("users").withIndex("by_email", (q) => q.eq("email", email.toLowerCase().trim())).first();
    return { exists: !!user, provider: user?.authProvider ?? null };
  },
});

// ─── Google ─────────────────────────────────────────────────────────

/** What the native app needs to start Google sign-in (client id is public). */
export const googleConfig = query({
  args: {},
  handler: async () => ({
    clientId: process.env.GOOGLE_CLIENT_ID ?? null,
    configured: !!process.env.GOOGLE_CLIENT_ID && !!process.env.GOOGLE_CLIENT_SECRET,
  }),
});

export const findUserByGoogleId = internalQuery({
  args: { googleId: v.string() },
  handler: async (ctx, { googleId }) =>
    ctx.db.query("users").withIndex("by_googleId", (q) => q.eq("googleId", googleId)).first(),
});

export const findUserByEmail = internalQuery({
  args: { email: v.string() },
  handler: async (ctx, { email }) =>
    ctx.db.query("users").withIndex("by_email", (q) => q.eq("email", email)).first(),
});

export const createGoogleUser = internalMutation({
  args: {
    email: v.string(),
    googleId: v.string(),
    name: v.optional(v.string()),
    firstName: v.optional(v.string()),
    lastName: v.optional(v.string()),
    profileImageUrl: v.optional(v.string()),
    device: v.optional(v.string()),
  },
  handler: async (ctx, args) => {
    const now = Date.now();
    const userId = await ctx.db.insert("users", {
      email: args.email,
      passwordHash: "",
      salt: "",
      name: args.name ?? fullName(args.firstName, args.lastName),
      firstName: args.firstName,
      lastName: args.lastName,
      profileImageUrl: args.profileImageUrl,
      googleId: args.googleId,
      authProvider: "google",
      emailVerified: true,
      createdAt: now,
      lastLoginAt: now,
    });
    const token = await createSession(ctx, userId, args.device);
    return { userId, token };
  },
});

export const linkGoogleAndSession = internalMutation({
  args: {
    userId: v.id("users"),
    googleId: v.string(),
    profileImageUrl: v.optional(v.string()),
    firstName: v.optional(v.string()),
    lastName: v.optional(v.string()),
    device: v.optional(v.string()),
  },
  handler: async (ctx, { userId, googleId, profileImageUrl, firstName, lastName, device }) => {
    const user = await ctx.db.get(userId);
    if (!user) throw new Error("User not found.");
    await ctx.db.patch(userId, {
      googleId,
      emailVerified: true,
      profileImageUrl: user.profileImageUrl ?? profileImageUrl,
      firstName: user.firstName ?? firstName,
      lastName: user.lastName ?? lastName,
    });
    const token = await createSession(ctx, userId, device);
    return token;
  },
});

export const userById = internalQuery({
  args: { userId: v.id("users") },
  handler: async (ctx, { userId }) => ctx.db.get(userId),
});

export async function exchangeGoogleCode(code: string, redirectUri: string) {
  const clientId = process.env.GOOGLE_CLIENT_ID;
  const clientSecret = process.env.GOOGLE_CLIENT_SECRET;
  if (!clientId || !clientSecret) throw new Error("Google OAuth is not configured on the server.");
  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ code, client_id: clientId, client_secret: clientSecret, redirect_uri: redirectUri, grant_type: "authorization_code" }),
  });
  if (!res.ok) {
    console.error("Google token exchange failed:", await res.text());
    throw new Error("Failed to exchange Google authorization code.");
  }
  const tokens = (await res.json()) as { id_token: string };
  return tokens.id_token;
}

export async function verifyGoogleIdToken(idToken: string) {
  const res = await fetch(`https://oauth2.googleapis.com/tokeninfo?id_token=${encodeURIComponent(idToken)}`);
  if (!res.ok) throw new Error("Invalid Google token.");
  const payload = (await res.json()) as {
    sub: string; email: string; email_verified: string; name?: string; given_name?: string; family_name?: string; picture?: string; aud: string;
  };
  const expected = process.env.GOOGLE_CLIENT_ID;
  if (expected && payload.aud !== expected) throw new Error("Google token audience mismatch.");
  if (payload.email_verified !== "true") throw new Error("Google email is not verified.");
  return {
    googleId: payload.sub,
    email: payload.email.toLowerCase().trim(),
    firstName: payload.given_name,
    lastName: payload.family_name,
    name: payload.name,
    profileImageUrl: payload.picture,
  };
}

/** Find or create the user for a verified Google profile and open a session. */
export async function signInWithGoogleProfile(
  ctx: { runQuery: (fn: any, args: any) => Promise<any>; runMutation: (fn: any, args: any) => Promise<any> },
  profile: { googleId: string; email: string; name?: string; firstName?: string; lastName?: string; profileImageUrl?: string },
  device?: string,
) {
  let user: any = await ctx.runQuery(internal.auth.findUserByGoogleId, { googleId: profile.googleId });
  let token: string;
  if (!user) user = await ctx.runQuery(internal.auth.findUserByEmail, { email: profile.email });
  if (user) {
    token = await ctx.runMutation(internal.auth.linkGoogleAndSession, {
      userId: user._id, googleId: profile.googleId, profileImageUrl: profile.profileImageUrl,
      firstName: profile.firstName, lastName: profile.lastName, device,
    });
    user = await ctx.runQuery(internal.auth.userById, { userId: user._id });
  } else {
    const created = await ctx.runMutation(internal.auth.createGoogleUser, { ...profile, device });
    token = created.token;
    user = await ctx.runQuery(internal.auth.userById, { userId: created.userId as Id<"users"> });
  }
  return { token, user: publicUser(user) };
}

/** Used when the client completed the OAuth code flow itself. */
export const googleLoginWithCode = action({
  args: { code: v.string(), redirectUri: v.string(), device: v.optional(v.string()) },
  handler: async (ctx, { code, redirectUri, device }) => {
    const idToken = await exchangeGoogleCode(code, redirectUri);
    const profile = await verifyGoogleIdToken(idToken);
    return signInWithGoogleProfile(ctx, profile, device);
  },
});
