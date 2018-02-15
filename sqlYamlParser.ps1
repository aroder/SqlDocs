param (
    [string]$output = "html", # can be html or wiki (mediawiki) or confluence (atlassian)
    [string]$DatabaseServer = "<DbServer>",
    [string]$Database = "<DbName>"
 )

Clear-Host
(new-object Net.WebClient).DownloadString("http://psget.net/GetPsGet.ps1") | iex
Import-Module PsGet
Install-Module PowerYaml
Import-Module PowerYaml.psm1 # import the YAML parser if necessary (get it via PSGET)
set-psdebug -strict # catch a few extra bugs

 
$SQL =@" 
SELECT
  ROUTINE_TYPE AS [type],
  ROUTINE_SCHEMA AS [schema],
  ROUTINE_NAME AS [name],
  CREATED AS [created],
  LAST_ALTERED AS [modified],
  DATA_TYPE AS returnType,
  ROUTINE_DEFINITION AS definition
FROM INFORMATION_SCHEMA.ROUTINES
WHERE ROUTINE_SCHEMA IN('dbo')
  AND (
    (
      ROUTINE_TYPE = 'FUNCTION'
    ) OR (
      ROUTINE_TYPE = 'PROCEDURE'
    )
  )
--ORDER BY ROUTINE_TYPE, ROUTINE_SCHEMA, ROUTINE_NAME

union 

select 
  'VIEW' as [type],
  table_schema as [schema],
  table_name as [name],
  null as [created],
  null as [modified],
  'TABLE' as returnType,
  view_definition as [definition]
 from information_schema.views
where table_schema in ('dbo')

"@
$scriptPath = Split-Path -parent $PSCommandPath
"The directory $($scriptPath) will contain the output"


function Parse-YamlDocs() {
    $functions = @() #initialise the array of hashtables
    $sprocs = @() # array of hashtables storing stored procedure information
    # create the SqlClient connection
    $conn = new-Object System.Data.SqlClient.SqlConnection("Server=$DatabaseServer;DataBase=$Database;Integrated Security=True")#
    $conn.Open() | out-null #open the connection

    # We add a handler for the warnings just in case we get one
    $message = [string]'';
    $handler = [System.Data.SqlClient.SqlInfoMessageEventHandler] { param ($sender,
                  $event)    $global:message = "$($message)`n $($event.Message)" };
    $conn.add_InfoMessage($handler);
    $conn.FireInfoMessageEventOnUserErrors = $true

    $cmd = new-Object System.Data.SqlClient.SqlCommand($SQL, $conn)
    $rdr = $cmd.ExecuteReader()
    $datatable = new-object System.Data.DataTable
    $datatable.Load($rdr)
    if ($message -ne '') { Write-Warning $message } # tell the user of any warnings or info messages

    foreach ($row in $datatable.Rows) # we read the routines row by row
    {
        if ("$($row['definition'])" -cmatch '(?ism)(\/\*\*).*?(summary.*?)(\*\*\/)')
        {
        #Write-Host $matches[2]
            $fn = @{}
            #parse the YAML into a hashtable
            try { 
                $fn = Get-Yaml $($matches[2])
            }
            catch {
                $fn.warning = "could not parse header for $($row['name']): " + $_ # the error message
                $fn.warningHeaderDocs = $($matches[2])
                write-warning $fn.warning 
            }
            #add the rest of the objects
            $fn.name = $row.name
            $fn.schema = $row.schema
            $fn.created = $row.created
            $fn.modified = $row.modified
            $fn.returnType = $row.returnType
            $fn.type = $row.type

            $functions += $fn; #and add-in each routine to the array.
            #Exit 0
        }
    }
    return $functions
}
function Generate-Html-Function-Param-Table($f) {
    # parameter list
    $pHtml = @"
            <table>
                <tr>
                    <th>Name</th>
                    <th>Type</th>
                    <th>Description</th>
                    <th>If NULL</th>
                </tr>

"@

    foreach ($p in $f.parameters) {
            $pHtml += @"
                <tr>
                    <td>$($p.name)</td>
                    <td>$($p.type)</td>
                    <td>$($p.description)</td>
                    <td>$($p.ifNull)</td>
                </tr>
"@
    }
    $pHtml += "</table>"
    return $pHtml;
}
function Generate-Html-Function-Examples($f) {
    # example list
    $eHtml = "<ol class=""examples"">"
    foreach ($e in $f.examples) {
        $eHtml += "<li>$($e)</li>"
    }
    $eHtml += "</ol>"
    return $eHtml;
}
function Generate-Html-Function-tickets($f) {
    $h = "<ul class=""tickets"">"
    foreach ($item in $f.relatedTickets) {
        $h += "<li><b><a href=""https://jira.internal.ofiglobal.net/browse/RUBICON-$($item.number)"" target=""_blank"">$($item.number)</a></b> - $($item.desc)</li>"
    }
    $h += "</ul>"
    return $h
}
function Generate-Html-Function($f) {
    $h = "<a name=""$($f.schema).$($f.name)""></a>"
    $h += "<h3>$($f.schema).$($f.name)</h3>"
    if ($f.type -ne 'VIEW') { $h += "<p>Created by $($f.author) on $($f.created)</p>" }
    $h += "<h4>Summary</h4>"
    $h += "<p>$($f.summary.replace("`n", "</p><p>"))</p>"
    if ($f.type -ne 'VIEW') {
        $h += "<h4>Parameters</h4>"
        if (0 -lt $f.parameters.Length) { $h += Generate-Html-Function-Param-Table($f) } else { $h += "none" }
        $h += "<h4>Returns $($f.returnType)</h4>"
        $h += "<p>$($f.returns)</p>"
    }
    if (0 -lt $f.examples.Length) {
        $h += "<h4>Examples</h4>"
        $h += Generate-Html-Function-Examples($f)
    }
    $h += "<h4>Related tickets</h4>"
    if (0 -lt $f.relatedTickets.Length) { $h += Generate-Html-Function-Tickets($f) } else { $h += "none" }
    $h += "<hr />"
    return $h;
}
function Generate-Html-Function-Menu($functions) {
    $h = "<ul>"
    foreach ($f in $functions) {
        $h += "<li><a href=""#$($f.schema).$($f.name)"">$($f.schema).$($f.name)</a></li>"
    }
    $h += "</ul>"

    return $h;
}
function Generate-Html($functions) {
    $html = Get-Content $scriptPath\documentationTemplate.html

    ######## HTML generation
    $html = $html.Replace("{{database}}", $DatabaseServer + "\" + $Database)

    $dateGenerated = Get-Date
    $html = $html.Replace("{{dateGenerated}}", $dateGenerated)


    #### do the functions' HTML
    $h = ""
    foreach ($f in $functions | Where { $_.type -eq 'FUNCTION' }) {
        $h += Generate-Html-Function($f);
    }
    $html = $html.Replace("{{functions}}", $h)

    # functions index/menu HTML block
    $h = Generate-Html-Function-Menu($functions | Where { $_.type -eq 'FUNCTION' })
    $html = $html.Replace("{{functionsIndex}}", $h)


    #### do the stored procedures' HTML
    $h = ""
    foreach ($f in $functions | Where { $_.type -eq 'PROCEDURE' }) {
        $h += Generate-Html-Function($f);
    }
    $html = $html.Replace("{{sprocs}}", $h);

    #sproc index/menu HTML block
    $h = Generate-Html-Function-Menu($functions | Where { $_.type -eq 'PROCEDURE' })
    $html = $html.Replace("{{sprocsIndex}}", $h)

    #### do the views' HTML
    $h = ""
    foreach ($f in $functions | Where { $_.type -eq 'VIEW'}) {
        $h += Generate-Html-Function($f);
    }
    $html = $html.Replace("{{views}}", $h);

    #view index/menu HTML block
    $h = Generate-Html-Function-Menu($functions | Where { $_.type -eq 'VIEW'})
    $html = $html.Replace("{{viewsIndex}}", $h)

    $html > $scriptPath\documentation.html
}


function Generate-Wiki($functions) {
    $functionHeaderTemplate = @"
== {0}.{1} == 

"@
    $functionTemplate = @"
== {0}.{1} == 

Created by {2} on {3} 

'''Summary'''

{4} 

'''Parameters'''

{{| class="wikitable"
! Name
! Type
! Description
! If NULL
{5}
|}}

'''Returns ''{6}'''''

{7}

'''Examples'''

{8}

'''Related Tickets'''

{9}

"@
    $wiki = @"
Generated on $(Get-Date) from '''$($DatabaseServer)\$($Database)'''

''Do not edit this wiki page directly.'' Instead, modify the header docs of your SQL function. For examples, see [[Sql_Object_Documentation#dbo.fnMedmDbVarValue|dbo.fnMedmDbVarValue]], [[Sql_Object_Documentation#ajr.fnIsPositive|ajr.fnIsPositive]], or [[Sql_Object_Documentation#dbo.fnUtilChars|dbo.fnUtilChars]]. Because we generate this documentation from the dev environment, ''you do not have to deploy a function just to update its inline documentation''. Just update it in the dev environment, and you are done.

[[File:SQL function inline documentation.png|200px]]

[[How to Generate Sql Object Documentation]]

"@

    $h = ""
    foreach ($f in $functions) {
        if ($f.warning) {
            $wiki += ($functionHeaderTemplate -f $f.schema, $f.name) + "$($f.warning)`r`n`r`n<nowiki>$($f.warningHeaderDocs)</nowiki>`r`n"
            continue
        }

        # parameter list
        $parmsWiki = ""
        foreach ($p in $f.parameters) {
            $parmsWiki += @"
|-
|@$($p.name)
|$($p.type)
|$($p.description)
|$($p.ifNull)

"@
        }

        # example list
        $egWiki = ""
        foreach ($e in $f.examples) {
            $egWiki += "# $($e)`r`n"
        }

        #related ticket list
        $ticketWiki = ""
        foreach ($ticket in $f.relatedTickets) {
            $ticketWiki += "* '''[https://jira.internal.ofiglobal.net/browse/RUBICON-$($ticket.number) $($ticket.number)]''' $($ticket.desc)`r`n"
        }
        if (0 -eq $ticketWiki.Length) { $ticketWiki = "none" }

        $functionWiki = $functionTemplate -f $f.schema, $f.name, $f.author, $f.created, $f.summary, $parmsWiki, $f.returnType, $f.returns, $egWiki, $ticketWiki
        $wiki += $functionWiki
    }

    $wiki > $scriptPath\documentation.wiki.txt
}


$sqlFunctions = Parse-YamlDocs
switch ($output) {
    "html" {
        Generate-Html $sqlFunctions  
    }
    "wiki" {
        Generate-Wiki $sqlFunctions
    }
}


