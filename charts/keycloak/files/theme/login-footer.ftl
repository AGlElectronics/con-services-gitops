<#macro content>
<#-- js/brand.js fetches the brand from Den's public endpoint (theme property denPublicUrl, from DEN_PUBLIC_URL). -->
<#if (properties.denPublicUrl)?has_content>
<div id="cs-brand" hidden data-den-url="${properties.denPublicUrl}"></div>
</#if>
</#macro>
