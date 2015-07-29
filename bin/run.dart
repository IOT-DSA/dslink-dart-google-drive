import "dart:async";
import "dart:convert";

import "package:googleapis/drive/v2.dart" as drive;
import "package:googleapis_auth/src/auth_http_utils.dart";
import "package:http/http.dart" as http;
import "package:googleapis_auth/auth_io.dart";
import "package:dslink/dslink.dart";
import "package:dslink/utils.dart" show alphabet;
import "package:dslink/nodes.dart";
import "package:csv/csv.dart";

LinkProvider link;

final List<String> SCOPES = [
  drive.DriveApi.DriveScope
];

main(List<String> args) async {
  link = new LinkProvider(args, "GoogleDrive-", defaultNodes: {
    "Add_Account": {
      r"$is": "addAccount",
      r"$name": "Add Account",
      r"$invokable": "write",
      r"$result": "values",
      r"$params": [
        {
          "name": "name",
          "description": "Account Name",
          "type": "string",
          "placeholder": "MyAccount"
        },
        {
          "name": "clientId",
          "description": "Client ID",
          "placeholder": "0123456789.apps.googleusercontent.com",
          "type": "string"
        },
        {
          "name": "clientSecret",
          "description": "Client Secret",
          "placeholder": "my_client_secret",
          "type": "string"
        }
      ],
      r"$columns": [
        {
          "name": "success",
          "type": "bool"
        },
        {
          "name": "message",
          "type": "string"
        }
      ]
    }
  }, profiles: {
    "account": (String path) => new AccountNode(path, link.provider),
    "addAccount": (String path) => new SimpleActionNode(path, (Map<String, dynamic> params) async {
      fail(String msg) {
        return {
          "success": false,
          "message": msg
        };
      }

      String name = params["name"];

      if (name == null || name.isEmpty) {
        return fail("'name' is required");
      }

      if (link["/"].children.containsKey(name)) {
        return fail("Account '${name}' already exists.");
      }

      link.addNode("/${name}", {
        r"$is": "account",
        r"$$client_id": params["clientId"],
        r"$$client_secret": params["clientSecret"]
      });

      link.save();

      return {
        "success": true,
        "message": "Success!"
      };
    }, link.provider)
  }, autoInitialize: false, exitOnFailure: true);

  link.init();
  link.connect();
}

class AccountNode extends SimpleNode {
  AutoRefreshingAuthClient client;
  drive.DriveApi api;

  AccountNode(String path, SimpleNodeProvider provider) : super(path, provider);

  Completer codeCompleter;

  @override
  onCreated() async {
    var clientId = configs[r"$$client_id"];
    var clientSecret = configs[r"$$client_secret"];
    var refreshToken = configs[r"$$refresh_token"];

    var cid = new ClientId(clientId, clientSecret);

    if (refreshToken == null) {
      var authUrlNode = createChild("Authorization_Url", {
        r"$name": "Authorization Url",
        r"$type": "string"
      })
        ..serializable = false;

      client = await clientViaUserConsentManual(cid, SCOPES, (uri) {
        var u = Uri.parse(uri);

        var params = new Map.from(u.queryParameters);

        params["access_type"] = "offline";

        if (u.queryParameters["access_type"] != "offline") {
          u = u.replace(queryParameters: params);
        }

        uri = u.toString();

        authUrlNode.updateValue(uri);
        codeCompleter = new Completer();

        var setAuthorizationCodeNode = new SimpleActionNode("${path}/Set_Authorization_Code", (Map<String, dynamic> params) async {
          var code = params["code"];

          if (code == null || code.isEmpty) {
            return null;
          }

          if (codeCompleter != null && !codeCompleter.isCompleted) {
            codeCompleter.complete(code);
          }
        }, provider);

        setAuthorizationCodeNode.serializable = false;

        setAuthorizationCodeNode.load({
          r"$name": "Set Authorization Code",
          r"$invokable": "write",
          r"$result": "values",
          r"$params": [
            {
              "name": "code",
              "type": "string",
              "description": "Authorization Code",
              "placeholder": "4/v6xr77ewYqhvHSyW6UJ1w7jKwAzu"
            }
          ]
        });

        provider.setNode(setAuthorizationCodeNode.path, setAuthorizationCodeNode);

        return codeCompleter.future;
      });

      configs[r"$$refresh_token"] = client.credentials.refreshToken;
      link.save();

      provider.removeNode("${path}/Set_Authorization_Code");
      provider.removeNode("${path}/Authorization_Url");

      init();
    } else {
      var creds = new AccessCredentials(new AccessToken("", "", new DateTime.now().toUtc()), refreshToken, SCOPES);
      var baseClient = new http.Client();
      creds = await refreshCredentials(cid, creds, baseClient);
      client = new AutoRefreshingClient(baseClient, cid, creds);
      init();
    }
  }

  init() async {
    api = new drive.DriveApi(client);
    var getSpreadsheetNode = new SimpleActionNode("${path}/Get_Spreadsheet", (Map<String, dynamic> params) async {
      var file = params["file"];

      if (file == null || file.isEmpty) {
        return new Table([], []);
      }

      try {
        drive.File f = await api.files.get(file);

        if (f is! drive.File) {
          throw new Exception(f);
        }

        if (!f.exportLinks.containsKey("text/csv")) {
          throw new Exception("Not a Spreadsheet");
        }

        var link = f.exportLinks["text/csv"];
        var response = await client.get(link);
        if (response.statusCode != 200) {
          throw new Exception("Failed to fetch spreadsheet. Status Code: ${response.statusCode}");
        }
        var body = response.body;

        return convertCsvToTable(body);
      } catch (e) {
        return new Table([
          new TableColumn("error", "string")
        ], [
          [
            e.toString()
          ]
        ]);

      }
    }, link.provider);

    var searchFilesNode = new SimpleActionNode("${path}/Search_Files", (Map<String, dynamic> params) async {
      var query = params["query"];

      if (query != null && query.trim().isEmpty) {
        query = null;
      }

      drive.FileList list = await api.files.list(q: query);
      List<drive.File> files = list.items;

      return files.map((x) {
        return {
          "title": x.title,
          "id": x.id,
          "description": x.description,
          "extension": x.fileExtension,
          "filename": x.originalFilename,
          "type": x.mimeType,
          "icon": x.iconLink,
          "downloadUrl": x.downloadUrl
        };
      }).toList();
    }, provider);

    searchFilesNode.load({
      r"$name": "Search Files",
      r"$invokable": "read",
      r"$result": "table",
      r"$params": [
        {
          "name": "query",
          "type": "string",
          "placeholder": "title = 'Golden Gate Bridge'",
          "description": "Search Query"
        }
      ],
      r"$columns": [
        {
          "name": "title",
          "type": "string"
        },
        {
          "name": "id",
          "type": "string"
        },
        {
          "name": "description",
          "type": "string"
        },
        {
          "name": "extension",
          "type": "string"
        },
        {
          "name": "filename",
          "type": "string"
        },
        {
          "name": "type",
          "type": "string"
        },
        {
          "name": "icon",
          "type": "string"
        },
        {
          "name": "downloadUrl",
          "type": "string"
        }
      ]
    });

    getSpreadsheetNode.load({
      r"$name": "Get Spreadsheet",
      r"$invokable": "read",
      r"$result": "table",
      r"$params": [
        {
          "name": "file",
          "type": "string",
          "description": "File ID",
          "placeholder": "1A4-3c9hL9K49AKd38aUJqjS3eLOCCzHzaOs2zPFiy7E"
        }
      ]
    });

    getSpreadsheetNode.serializable = false;
    searchFilesNode.serializable = false;

    provider.setNode(getSpreadsheetNode.path, getSpreadsheetNode);
    provider.setNode(searchFilesNode.path, searchFilesNode);
  }

  @override
  onRemoving() {
    if (client != null) {
      client.close();
    }
  }
}

Table convertCsvToTable(String csv) {
  var decoder = new CsvToListConverter();
  var lists = decoder.convert(csv);

  if (lists.isEmpty) {
    return new Table([], []);
  }

  var columns = new List.generate(lists.first.length, (i) => new TableColumn(columnIndexToName(i), "dynamic"));
  return new Table(columns, lists);
}

String columnIndexToName(int n) {
  if (n < 26) {
    return alphabet[n];
  }
  var letters = [];
  for (var i = 0; i < n; i++) {
    if (letters.isEmpty) {
      letters.add("A");
      continue;
    }

    var n = letters.last;
    if (n == "Z") {
      letters.add("A");
      continue;
    } else {
      n = letters[letters.indexOf(n) + 1];
      letters[letters.length - 1] = n;
    }
  }
  return letters.join();
}
