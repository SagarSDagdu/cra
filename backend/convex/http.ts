import { httpRouter } from "convex/server";
import { httpAction } from "./_generated/server";
import { exchangeGoogleCode, signInWithGoogleProfile, verifyGoogleIdToken } from "./auth";

const http = httpRouter();

function page(title: string, body: string, deepLink?: string) {
  const meta = deepLink ? `<meta http-equiv="refresh" content="0;url=${deepLink}">` : "";
  return `<!doctype html><html><head><meta charset="utf-8">${meta}<title>${title}</title>
<style>html{background:#1c242b;color:#f4f1ea;font:16px -apple-system,system-ui}body{display:flex;min-height:90vh;align-items:center;justify-content:center;margin:0}
main{max-width:420px;padding:32px;text-align:center}h1{font-size:22px;margin:0 0 10px}p{opacity:.75}a{display:inline-block;margin-top:18px;padding:10px 18px;border-radius:10px;background:#6944ae;color:#fff;text-decoration:none;font-weight:600}</style>
</head><body><main><h1>${title}</h1><p>${body}</p>${deepLink ? `<a href="${deepLink}">Open Cra</a>` : ""}</main></body></html>`;
}

// Google redirects here with ?code=… ; we exchange it, open a session and
// hand the result back to the app through the cra:// scheme (same pattern as
// GhostWriter's /google-callback → ghostwriter://auth-callback).
http.route({
  path: "/google-callback",
  method: "GET",
  handler: httpAction(async (ctx, request) => {
    const url = new URL(request.url);
    const code = url.searchParams.get("code");
    const error = url.searchParams.get("error");
    const headers = { "Content-Type": "text/html" };
    if (error) return new Response(page("Sign-in cancelled", "You can close this window."), { status: 400, headers });
    if (!code) return new Response(page("Sign-in failed", "No authorization code received."), { status: 400, headers });
    try {
      const redirectUri = `${url.origin}/google-callback`;
      const idToken = await exchangeGoogleCode(code, redirectUri);
      const profile = await verifyGoogleIdToken(idToken);
      const device = url.searchParams.get("state") ?? undefined;
      const result = await signInWithGoogleProfile(ctx, profile, device);
      const payload = btoa(JSON.stringify(result));
      const deepLink = `cra://auth-callback?data=${encodeURIComponent(payload)}`;
      return new Response(page(`Signed in as ${result.user.name ?? result.user.email}`, "Taking you back to Cra…", deepLink), { status: 200, headers });
    } catch (err) {
      console.error("Google OAuth callback error:", err);
      return new Response(page("Sign-in failed", "Something went wrong. Please try again."), { status: 500, headers });
    }
  }),
});

http.route({
  path: "/health",
  method: "GET",
  handler: httpAction(async () => new Response("ok", { status: 200 })),
});

export default http;
