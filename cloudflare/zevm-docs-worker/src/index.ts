const DOCS_PATH_PREFIX = "/docs";

interface Env {
  ASSETS: Fetcher;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === "/" || url.pathname === "") {
      const redirectUrl = new URL(request.url);
      redirectUrl.pathname = DOCS_PATH_PREFIX;
      redirectUrl.search = "";
      return Response.redirect(redirectUrl, 302);
    }

    if (url.pathname === DOCS_PATH_PREFIX) {
      return serveAsset(request, env, "/");
    }

    if (url.pathname.startsWith(`${DOCS_PATH_PREFIX}/`)) {
      if (url.pathname === `${DOCS_PATH_PREFIX}/404` || url.pathname === `${DOCS_PATH_PREFIX}/404/`) {
        return new Response("Not found", { status: 404 });
      }

      if (!hasFileExtension(url.pathname) && !url.pathname.endsWith("/")) {
        const redirectUrl = new URL(request.url);
        redirectUrl.pathname = `${url.pathname}/`;
        return Response.redirect(redirectUrl, 302);
      }

      const assetPath = url.pathname.slice(DOCS_PATH_PREFIX.length) || "/";
      const response = await serveAsset(request, env, assetPath);
      return response.status === 404 ? new Response("Not found", { status: 404 }) : response;
    }

    if (isExportAssetPath(url.pathname)) {
      return serveAsset(request, env, url.pathname);
    }

    if (request.method === "GET" || request.method === "HEAD") {
      const redirectUrl = new URL(request.url);
      redirectUrl.pathname = `${DOCS_PATH_PREFIX}${url.pathname}`;
      return Response.redirect(redirectUrl, 302);
    }

    return new Response("Not found", { status: 404 });
  },
};

function isExportAssetPath(pathname: string): boolean {
  return (
    pathname.startsWith("/_astro/") ||
    pathname.startsWith("/pagefind/") ||
    pathname === "/favicon.svg" ||
    pathname === "/sitemap-index.xml" ||
    pathname === "/sitemap-0.xml"
  );
}

function hasFileExtension(pathname: string): boolean {
  const lastSegment = pathname.split("/").pop() ?? "";
  return lastSegment.includes(".");
}

function serveAsset(request: Request, env: Env, pathname: string): Promise<Response> {
  const assetUrl = new URL(request.url);
  assetUrl.pathname = pathname;
  return env.ASSETS.fetch(new Request(assetUrl, request));
}
