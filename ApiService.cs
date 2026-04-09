using System.Net.Http;
using System.Threading.Tasks;

namespace ReactApp.Services;

/// <summary>
/// Fetches data from external APIs.
/// NOTE: Uses direct HttpClient instantiation — should use IHttpClientFactory.
/// </summary>
public class ApiService
{
    public async Task<string> GetUserDataAsync(string userId)
    {
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
