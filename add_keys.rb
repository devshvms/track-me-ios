require 'json'

file_path = 'track-me-ios/Localizable.xcstrings'
data = JSON.parse(File.read(file_path))

keys = {
  "Location access needed" => {
    "de" => "Standortzugriff erforderlich",
    "es" => "Se necesita acceso a la ubicación",
    "fr" => "Accès à la position requis",
    "hi" => "स्थान तक पहुंच आवश्यक है",
    "ja" => "位置情報へのアクセスが必要です",
    "zh-Hans" => "需要位置权限"
  },
  "Open Settings" => {
    "de" => "Einstellungen öffnen",
    "es" => "Abrir ajustes",
    "fr" => "Ouvrir les réglages",
    "hi" => "सेटिंग्स खोलें",
    "ja" => "設定を開く",
    "zh-Hans" => "打开设置"
  },
  "Location access is turned off for TrackMe. Turn it on in Settings to record a ride — your route always stays on your device first." => {
    "de" => "Der Standortzugriff ist für TrackMe deaktiviert. Aktiviere ihn in den Einstellungen, um eine Fahrt aufzuzeichnen – deine Route bleibt immer zuerst auf deinem Gerät.",
    "es" => "El acceso a la ubicación está desactivado para TrackMe. Actívalo en Ajustes para registrar un recorrido; tu ruta siempre se guarda primero en tu dispositivo.",
    "fr" => "L'accès à la position est désactivé pour TrackMe. Activez-le dans les Réglages pour enregistrer un trajet — votre itinéraire reste toujours sur votre appareil en premier.",
    "hi" => "TrackMe के लिए स्थान तक पहुंच बंद है। राइड रिकॉर्ड करने के लिए इसे सेटिंग्स में चालू करें — आपका रूट हमेशा पहले आपके डिवाइस पर रहता है।",
    "ja" => "TrackMe の位置情報へのアクセスがオフになっています。ライドを記録するには、設定でオンにしてください。ルートは常にまずデバイス上に保存されます。",
    "zh-Hans" => "TrackMe 的位置访问权限已关闭。请在设置中开启以记录骑行——您的路线始终优先保留在设备上。"
  }
}

keys.each do |english, translations|
  data["strings"][english] = {
    "extractionState" => "manual",
    "localizations" => {
      "en" => {
        "stringUnit" => {
          "state" => "translated",
          "value" => english
        }
      }
    }
  }

  translations.each do |lang, trans|
    data["strings"][english]["localizations"][lang] = {
      "stringUnit" => {
        "state" => "translated",
        "value" => trans
      }
    }
  end
end

File.write(file_path, JSON.pretty_generate(data))
puts "Updated Localizable.xcstrings successfully!"
