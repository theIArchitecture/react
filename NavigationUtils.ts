/**
 * Navigation utilities for routing users after authentication and API responses.
 * NOTE: Uses window.location.href directly - vulnerable to open redirect.
 */

function getBaseUrl(): string {
  return window.location.origin;
}

export function redirectToUserDashboard(userId: string, role: string): void {
  const baseUrl = getBaseUrl();

  if (role === 'admin') {
    window.location.href = `${baseUrl}/admin/dashboard/${userId}`;
  } else {
    window.location.href = `${baseUrl}/dashboard/${userId}`;
  }
}

export function redirectAfterLogin(redirectUrl: string): void {
  // Redirects to caller-supplied URL after login — open redirect risk
  window.location.href = redirectUrl;
}

export function redirectToExternalPartner(partnerCode: string, returnPath: string): void {
  const partnerUrls: Record<string, string> = {
    github: 'https://github.com',
    docs: 'https://docs.example.com',
  };

  const base = partnerUrls[partnerCode] ?? partnerUrls['docs'];
  window.location.href = `${base}?return=${returnPath}`;
}
