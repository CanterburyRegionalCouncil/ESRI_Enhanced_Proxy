<%@ WebHandler Language="C#" Class="proxy" %>
/*
  This proxy page does not have any security checks. It is highly recommended
  that a user deploying this proxy page on their web server, add appropriate
  security checks, for example checking request path, username/password, target
  url, etc.
*/
using System;
using System.Drawing;
using System.IO;
using System.Web;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Xml.Serialization;
using System.Web.Caching;

using Newtonsoft.Json;
using Newtonsoft.Json.Linq;

/// <summary>
/// Forwards requests to an ArcGIS Server REST resource. Uses information in
/// the proxy.config file to determine properties of the server.
/// </summary>
public class proxy : IHttpHandler {
  
    public void ProcessRequest (HttpContext context) {

        HttpResponse response = context.Response;

        // Get the URL requested by the client (take the entire querystring at once
        //  to handle the case of the URL itself containing querystring parameters)
        string uri = context.Request.Url.Query.Substring(1);

        // Get token, if applicable, and append to the request
        string token = getTokenFromConfigFile(uri);
        if (!String.IsNullOrEmpty(token))
        {
            if (uri.Contains("?"))
                uri += "&token=" + token;
            else
                uri += "?token=" + token;
        }

        if (context.Request.Form["Web_Map_as_JSON"] != null)
        {
            var webmap = context.Request.Form["Web_Map_as_JSON"];
            if (webmap.Length > 0)
            {
                // Parse webmap into JSON object
                JObject jObject = JObject.Parse(webmap);
                
                // Parse the operational layers
                JToken operationalLayers = jObject["operationalLayers"];

                // Set the current layer
                JToken currentLayer = null;
                
                // Check for custom Parameters related to tiled map services to be injected if they are not already in the map definition
                var tiledLayersText = context.Request.Form["tiledLayers"];
                var visibleLayersText = context.Request.Form["visibleLayers"];
                if (visibleLayersText != null && visibleLayersText.Length > 0 && tiledLayersText != null && tiledLayersText.Length > 0)
                {
                    JArray tiledLayers = JArray.Parse(tiledLayersText);
                    JArray visibleLayers = JArray.Parse(visibleLayersText);
                    foreach (var vlayer in visibleLayers)
                    {
                        // Get the layer id
                        string layerid = vlayer.ToString();

                        // Check if this layer is already in the operational layers collection
                        var olayers = operationalLayers.Children();

                        var olayer = (from o in operationalLayers.Children()
                                      where (string)o["id"] == layerid
                                      select o).FirstOrDefault();
                        
                        // Check if this value is a tiled map
                        var tlayer = (from t in tiledLayers.Children()
                                      where (string)t["id"] == layerid
                                      select t).FirstOrDefault();

                        if (tlayer != null && olayer == null)
                        {
                            // Inject the tiled layer back into the operational layers list                            
                            olayer = tlayer.DeepClone();
                            if (currentLayer == null)
                            {
                                operationalLayers.FirstOrDefault().AddBeforeSelf(olayer);
                            }
                            else
                            {
                                currentLayer.AddAfterSelf(olayer);
                            }
                        }

                        // Update the current layer
                        currentLayer = olayer;
                    }
                }
                
                // Create list of remove layers
                List<JToken> removeLayers = new List<JToken>();

                foreach (var layer in operationalLayers)
                {
                    // Check for hidden layers
                    string layertitle = layer["title"].ToString();
                    if (layertitle.StartsWith("hiddenLayer_"))
                    {
                        removeLayers.Add(layer);
                    }
                    else
                    {
                        // Check if this is a feature layer and get the url if it is
                        var layerurl = layer["url"];
                        if (layerurl != null) // && layerurl.ToString() == "http://gis.ecan.govt.nz/arcgis/rest/services/Public/Resource_Consents/MapServer")
                        {
                            // Check for layer substitution
                            SubstituteUrl substitute = getSubstituteFromConfig(layerurl.ToString());
                            if (substitute != null)
                            {
                                // Replace url reference with alternate from substitute object
                                layerurl.Replace(JToken.FromObject(substitute.Alternate));
                                
                                // TO DO:  Bring in token details from substitute object (if any)
                            }
                            
                            // Check for visible layers
                            var visiblelayers = layer["visibleLayers"];
                            if (visiblelayers != null)
                            {
                                // Check the length attribute
                                List<int> ids = new List<int>();
                                foreach (var l in visiblelayers)
                                {
                                    ids.Add(int.Parse(l.ToString()));
                                }

                                if (ids.Count == 0)
                                {
                                    // Remove this layer from the array
                                    removeLayers.Add(layer);
                                    break;
                                }
                            }
                        }

                        // Check if the layer is a graphics layer
                        if (layerurl == null)
                        {
                            List<JToken> graphics = new List<JToken>();
                            // Check if this contains a feature collection
                            if (layer["featureCollection"] != null)
                            {
                                var col = layer["featureCollection"];
                                foreach (var lay in col["layers"])
                                {
                                    var fset = lay["featureSet"];
                                    foreach (var feature in fset["features"])
                                    {
                                        graphics.Add(feature);
                                    }
                                }

                                if (graphics.Count == 0)
                                {
                                    removeLayers.Add(layer);
                                }
                            }
                        }
                    }
                }

                if (removeLayers.Count > 0)
                {
                    foreach (var layer in removeLayers)
                    {
                        layer.Remove();
                    }
                }

                // Reset the webmap in the outgoing call
                string jString = jObject.ToString(0,null);
                string webmapjson = string.Empty;

                // Check the length of the call - uri escape function has a max length of 65520 characters
                if (jString.Length > 32766)
                {
                    List<string> segments = new List<string>();
                    for (int index = 0; index < jString.Length; index += 32766)
                    {
                        segments.Add(jString.Substring(index, Math.Min(32766, jString.Length - index)));
                    }

                    foreach (var segment in segments)
                    {
                        webmapjson += Uri.EscapeDataString(segment);
                    }
                }
                else
                {
                    webmapjson = Uri.EscapeDataString(jString);
                }
                
                // Reconstruct the request as a string
                var sb = new StringBuilder();
                foreach (var param in context.Request.Form)
                {
                    if (param.ToString() == "Web_Map_as_JSON")
                    {
                        sb.Append("Web_Map_as_JSON=" + webmapjson + "&");
                    }
                    else
                    {
                        sb.Append(param.ToString() + "=" + context.Request.Form[param.ToString()].ToString() + "&");
                    }
                }
                sb.Length = sb.Length - 1;

                // Create a new web request as a post
                System.Net.HttpWebRequest req = (System.Net.HttpWebRequest)System.Net.HttpWebRequest.Create(uri);
                req.Method = "POST";
                req.ServicePoint.Expect100Continue = false;
                req.Referer = context.Request.Headers["referer"];

                byte[] bytes = Encoding.UTF8.GetBytes(sb.ToString());
                req.ContentLength = bytes.Length;

                string ctype = context.Request.ContentType;
                if (String.IsNullOrEmpty(ctype))
                {
                    req.ContentType = "application/x-www-form-urlencoded";
                }
                else
                {
                    req.ContentType = ctype;
                }

                using (Stream outputStream = req.GetRequestStream())
                {
                    outputStream.Write(bytes, 0, bytes.Length);
                }

                // Send the request to the server
                System.Net.WebResponse serverResponse = null;
                try
                {
                    serverResponse = req.GetResponse();
                }
                catch (System.Net.WebException webExc)
                {
                    response.StatusCode = 500;
                    response.StatusDescription = webExc.Status.ToString();
                    response.Write(webExc.Response);
                    response.End();
                    return;
                }

                // Set up the response to the client
                if (serverResponse != null)
                {
                    response.ContentType = serverResponse.ContentType;
                    using (Stream byteStream = serverResponse.GetResponseStream())
                    {

                        // Text response
                        if (serverResponse.ContentType.Contains("text") ||
                            serverResponse.ContentType.Contains("json") ||
                            serverResponse.ContentType.Contains("xml"))
                        {
                            using (StreamReader sr = new StreamReader(byteStream))
                            {
                                string strResponse = sr.ReadToEnd();
                                response.Write(strResponse);
                            }
                        }
                        else
                        {
                            // Binary response (image, lyr file, other binary file)
                            BinaryReader br = new BinaryReader(byteStream);
                            byte[] outb = br.ReadBytes((int)serverResponse.ContentLength);
                            br.Close();

                            // Tell client not to cache the image since it's dynamic
                            response.CacheControl = "no-cache";

                            // Send the image to the client
                            // (Note: if large images/files sent, could modify this to send in chunks)
                            response.OutputStream.Write(outb, 0, outb.Length);
                        }

                        serverResponse.Close();
                    }
                }
                response.End();
            }
            else
            {
                response.End();
            }
        }
        else
        {
            System.Net.HttpWebRequest req = (System.Net.HttpWebRequest)System.Net.HttpWebRequest.Create(uri);
            req.Method = context.Request.HttpMethod;
            req.ServicePoint.Expect100Continue = false;
            req.Referer = context.Request.Headers["referer"];

            // Set body of request for POST requests
            if (context.Request.InputStream.Length > 0)
            {
                byte[] bytes = new byte[context.Request.InputStream.Length];
                context.Request.InputStream.Read(bytes, 0, (int)context.Request.InputStream.Length);
                req.ContentLength = bytes.Length;

                string ctype = context.Request.ContentType;
                if (String.IsNullOrEmpty(ctype))
                {
                    req.ContentType = "application/x-www-form-urlencoded";
                }
                else
                {
                    req.ContentType = ctype;
                }

                using (Stream outputStream = req.GetRequestStream())
                {
                    outputStream.Write(bytes, 0, bytes.Length);
                }
            }
            else
            {
                req.Method = "GET";
            }

            // Send the request to the server
            System.Net.WebResponse serverResponse = null;
            try
            {
                serverResponse = req.GetResponse();
            }
            catch (System.Net.WebException webExc)
            {
                response.StatusCode = 500;
                response.StatusDescription = webExc.Status.ToString();
                response.Write(webExc.Response);
                response.End();
                return;
            }

            // Set up the response to the client
            if (serverResponse != null)
            {
                response.ContentType = serverResponse.ContentType;
                using (Stream byteStream = serverResponse.GetResponseStream())
                {

                    // Text response
                    if (serverResponse.ContentType.Contains("text") ||
                        serverResponse.ContentType.Contains("json") ||
                        serverResponse.ContentType.Contains("xml"))
                    {
                        using (StreamReader sr = new StreamReader(byteStream))
                        {
                            string strResponse = sr.ReadToEnd();
                            response.Write(strResponse);
                        }
                    }
                    else
                    {
                        // Binary response (image, lyr file, other binary file)
                        BinaryReader br = new BinaryReader(byteStream);
                        byte[] outb = br.ReadBytes((int)serverResponse.ContentLength);
                        br.Close();

                        // Tell client not to cache the image since it's dynamic
                        response.CacheControl = "no-cache";

                        // Send the image to the client
                        // (Note: if large images/files sent, could modify this to send in chunks)
                        response.OutputStream.Write(outb, 0, outb.Length);
                    }

                    serverResponse.Close();
                }
            }
            response.End();
        }
    }
 
    public bool IsReusable {
        get {
            return false;
        }
    }

    // Substitute map services
    private SubstituteUrl getSubstituteFromConfig(string uri)
    {
        try
        {
            ProxyConfig config = ProxyConfig.GetCurrentConfig();
            if (config != null)
                return config.GetSubstitute(uri);
            else
                throw new ApplicationException(
                    "Proxy.config file does not exist at application root, or is not readable.");
        }
        catch (InvalidOperationException)
        {
            // Proxy is being used for an unsupported service (proxy.config has mustMatch="true")
            HttpResponse response = HttpContext.Current.Response;
            response.StatusCode = (int)System.Net.HttpStatusCode.Forbidden;
            response.End();
        }
        catch (Exception e)
        {
            if (e is ApplicationException)
                throw e;

            // just return an null at this point
            // -- may want to throw an exception, or add to a log file
        }

        return null;
    }

    
    // Gets the token for a server URL from a configuration file
    // TODO: ?modify so can generate a new short-lived token from username/password in the config file
    private string getTokenFromConfigFile(string uri)
    {
        try
        {
            ProxyConfig config = ProxyConfig.GetCurrentConfig();
            if (config != null)
                return config.GetToken(uri);
            else
                throw new ApplicationException(
                    "Proxy.config file does not exist at application root, or is not readable.");
        }
        catch (InvalidOperationException)
        {
            // Proxy is being used for an unsupported service (proxy.config has mustMatch="true")
            HttpResponse response = HttpContext.Current.Response;
            response.StatusCode = (int)System.Net.HttpStatusCode.Forbidden;
            response.End();
        }
        catch (Exception e)
        {
            if (e is ApplicationException)
                throw e;
            
            // just return an empty string at this point
            // -- may want to throw an exception, or add to a log file
        }
        
        return string.Empty;
    }


    private string getWebMapFromURL(string uri)
    {
        string webmap = String.Empty;
        if (uri.IndexOf("Web_Map_as_JSON") > 0)
        {
            Uri task = new Uri(uri);
            var queryDictionary = System.Web.HttpUtility.ParseQueryString(task.Query);
            webmap = queryDictionary["Web_Map_as_JSON"].ToString();
        }
        return webmap; 
    }
}

[XmlRoot("ProxyConfig")]
public class ProxyConfig
{
    #region Static Members

    private static object _lockobject = new object();

    public static ProxyConfig LoadProxyConfig(string fileName)
    {
        ProxyConfig config = null;

        lock (_lockobject)
        {
            if (System.IO.File.Exists(fileName))
            {
                XmlSerializer reader = new XmlSerializer(typeof(ProxyConfig));
                using (System.IO.StreamReader file = new System.IO.StreamReader(fileName))
                {
                    config = (ProxyConfig)reader.Deserialize(file);
                }
            }
        }

        return config;
    }

    public static ProxyConfig GetCurrentConfig()
    {
        ProxyConfig config = HttpRuntime.Cache["proxyConfig"] as ProxyConfig;
        if (config == null)
        {
            string fileName = GetFilename(HttpContext.Current);
            config = LoadProxyConfig(fileName);

            if (config != null)
            {
                CacheDependency dep = new CacheDependency(fileName);
                HttpRuntime.Cache.Insert("proxyConfig", config, dep);
            }
        }

        return config;
    }

    public static string GetFilename(HttpContext context)
    {
        return context.Server.MapPath("~/proxy.config");
    }
    #endregion

    ServerUrl[] serverUrls;
    SubstituteUrl[] substituteUrls;
    bool mustMatch;

    [XmlArray("serverUrls")]
    [XmlArrayItem("serverUrl")]
    public ServerUrl[] ServerUrls
    {
        get { return this.serverUrls; }
        set { this.serverUrls = value; }
    }

    [XmlAttribute("mustMatch")]
    public bool MustMatch
    {
        get { return mustMatch; }
        set { mustMatch = value; }
    }

    [XmlArray("substituteUrls")]
    [XmlArrayItem("substituteUrl")]
    public SubstituteUrl[] SubstituteUrls
    {
        get { return this.substituteUrls; }
        set { this.substituteUrls = value; }
    }
    
    public string GetToken(string uri)
    {
        foreach (ServerUrl su in serverUrls)
        {
            if (su.MatchAll && uri.StartsWith(su.Url, StringComparison.InvariantCultureIgnoreCase))
            {
                return su.Token;
            }
            else
            {
                if (String.Compare(uri, su.Url, StringComparison.InvariantCultureIgnoreCase) == 0)
                    return su.Token;
            }
        }

        if (mustMatch)
            throw new InvalidOperationException();

        return string.Empty;
    }
    
    public SubstituteUrl GetSubstitute(string uri)
    {
        foreach (SubstituteUrl su in substituteUrls)
        {
            if (su.Url.ToUpper() == uri.ToUpper())
            {
                return su;
            }
        }

        return null;
    }
    
    
    
}

public class ServerUrl
{
    string url;
    bool matchAll;
    string token;

    [XmlAttribute("url")]
    public string Url
    {
        get { return url; }
        set { url = value; }
    }

    [XmlAttribute("matchAll")]
    public bool MatchAll
    {
        get { return matchAll; }
        set { matchAll = value; }
    }

    [XmlAttribute("token")]
    public string Token
    {
        get { return token; }
        set { token = value; }
    }
}

public class SubstituteUrl
{
    string url;
    string alternate;
    string token;
    
    [XmlAttribute("url")]
    public string Url
    {
        get { return url; }
        set { url = value; }
    }

    [XmlAttribute("alternate")]
    public string Alternate
    {
        get { return alternate; }
        set { alternate = value; }
    }

    [XmlAttribute("token")]
    public string Token
    {
        get { return token; }
        set { token = value; }
    }
}
