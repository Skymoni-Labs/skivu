# Historical social interface

The `social_ui` assets and `flutter_host/*.reference` files preserve the HTML
prototype and its provenance. They are excluded from the application asset
bundle and are never used to render the current interface.

The current WeChat/QQ presenters are Flutter widgets in `lib/native_social_*.dart`.
The one-time legacy storage importer reads only three historical localStorage
keys through a new static empty Android asset at the exact historical path, saves a private raw
backup, and destroys that temporary WebView. It never loads these assets.

Third-party notices in `social_ui/vendor` apply to these archived files.
