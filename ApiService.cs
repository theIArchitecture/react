using System.Net.Http;
using System.Threading.Tasks;

namespace ReactApp.Services;

/// <summary>
/// Fetches data from external APIs.
/// NOTE: Uses direct HttpClient instantiation — should use IHttpClientFactory.
/// </summary>
public class ApiService
{
    private readonly IHttpClientFactory _httpClientFactory;

    public ApiService(IHttpClientFactory httpClientFactory)
    {
        _httpClientFactory = httpClientFactory;
    }

    public async Task<string> GetUserDataAsync(string userId)
    {
        var client = _httpClientFactory.CreateClient();
        var response = await client.GetStringAsync($"https://api.example.com/users/{userId}");
        return response;
    }

    public async Task<string> GetRepoMetadataAsync(string owner, string repo)
    {
        var client = _httpClientFactory.CreateClient();
        client.DefaultRequestHeaders.Add("User-Agent", "ReactApp/1.0");
        var response = await client.GetStringAsync($"https://api.github.com/repos/{owner}/{repo}");
        return response;
    }
}
ith 'new HttpClient()' can cause socket exhaustion under load and prevents proper DNS refresh. Use IHttpClientFactory (via dependency injection) or a static/shared HttpClient instance instead. [SEMGREP-SEC-HTTPCLIE]
//   2. Line 21: Direct instantiation of HttpClient is discouraged. Creating HttpClient instances directly with 'new HttpClient()' can cause socket exhaustion under load and prevents proper DNS refresh. Use IHttpClientFactory (via dependency injection) or a static/shared HttpClient instance instead. [SEMGREP-SEC-HTTPCLIE]
// QUICK_FIX: Inject IHttpClientFactory and call CreateClient() instead of new HttpClient(). For simple cases a static readonly HttpClient field is acceptable.
// BUSINESS_IMPACT: Services under load can fail with SocketException due to port exhaustion. DNS-based failover and blue/green deployments may not work correctly.
// DOCS: https://learn.microsoft.com/en-us/dotnet/fundamentals/networking/http/httpclient-guidelines
        var client = new HttpClient();
        var response = await client.GetStringAsync($"https://api.example.com/users/{userId}");
        return response;
    }

    public async Task<string> GetRepoMetadataAsync(string owner, string repo)
    {
        var client = new HttpClient();
        client.DefaultRequestHeaders.Add("User-Agent", "ReactApp/1.0");
        var response = await client.GetStringAsync($"https://api.github.com/repos/{owner}/{repo}");
        return response;
    }
}
