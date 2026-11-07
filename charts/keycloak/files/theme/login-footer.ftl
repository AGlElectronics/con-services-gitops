<#macro content>
<#-- Brand pushed into the realm by Den (attribute conservicesBrand); read by js/brand.js. -->
<#if (realm.attributes["conservicesBrand"])??>
<div id="cs-brand" hidden data-brand="${realm.attributes["conservicesBrand"]}"></div>
</#if>
</#macro>
