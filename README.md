ESRI Enhanced Proxy
===================

ESRI Enhanced Web Map Proxy, proxy that helps with improving the web printing.

The proxy allows for the changing out tile map services to dynamic map services so that the user can increase the resolution that the map is produced higher than what the tile services have been created for.

It can also allow if coded at the client end, extra scales that are not possible under the tile services.


For Substituting tile services for dynamis ones .... use these xml tags

i.e. 

tile service
``
url="http://arcgis.ecan.govt.nz/ArcGIS/rest/services/Imagery/MapServer"
``

dynamic one to change out to
``
alternate="http://arcgis.ecan.govt.nz/arcgis/rest/services/Dynamic/Imagery_Latest/MapServer"
``

``
	<substituteUrls>
		<!-- serverUrl options:
			url = location of the ArcGIS Server map service that is to be substituted/swapped out.
			alternate = location of the ArcGIS Server map service that is to be used instead of the given url.
	    -->

		<!-- Imagery Service-->
    <substituteUrl url="http://arcgis.ecan.govt.nz/ArcGIS/rest/services/Imagery/MapServer"
            alternate="http://arcgis.ecan.govt.nz/arcgis/rest/services/Dynamic/Imagery_Latest/MapServer"></substituteUrl>
  </substituteUrls>
``
