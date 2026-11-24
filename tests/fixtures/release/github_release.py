"""In-memory GitHub release API with an injectable asset-upload failure."""
from pathlib import Path
import subprocess
from urllib.parse import parse_qs, urlsplit


class GitHubRelease:
    def __init__(self, repo, create_tag):
        self.repo = repo
        self.releases = {}
        self.tags = {}
        self.create_tag = create_tag
        self.fail_upload = True
        self.next_id = 1
        self.published = []

    def api(self, endpoint, *args, payload=None):
        if endpoint.startswith(f"{self.repo}/git/"):
            version = endpoint.rsplit("/", 1)[1]
            if "/matching-refs/" in endpoint:
                return [{"ref": "refs/tags/" + version}] if version in self.tags else []
            return {"object": {"type": "commit", "sha": self.tags[version]}}

        path = urlsplit(endpoint).path.lstrip("/")
        release_path = f"{self.repo}/releases"
        assert path.startswith(release_path)
        if path == release_path:
            if args == ("--paginate", "--slurp"):
                return [[{"tag_name": "older", "draft": False}], list(self.releases.values())]
            assert args == ("--method", "POST") and payload["draft"]
            assert not self.tags
            release_id = self.next_id
            self.next_id += 1
            draft = {"id": release_id, **payload, "assets": {},
                     "upload_url": f"https://uploads.github.com/{path}/{release_id}/assets{{?name,label}}"}
            self.releases[release_id] = draft
            return draft

        release_id = int(path[len(release_path) + 1:].split("/")[0])
        draft = self.releases[release_id]
        assert draft["draft"] and not self.tags
        if path.endswith("/assets"):
            if args == ("--paginate", "--slurp"):
                return [list(draft["assets"].values())]
            if self.fail_upload and draft["assets"]:
                raise subprocess.CalledProcessError(1, ["gh", "api", endpoint])
            name, = parse_qs(urlsplit(endpoint).query)["name"]
            asset = Path(args[args.index("--input") + 1])
            draft["assets"][name] = {"name": name, "state": "uploaded", "size": asset.stat().st_size}
            return draft["assets"][name]
        if args == ("--method", "DELETE"):
            del self.releases[release_id]
            return None
        assert args == ("--method", "PATCH") and not payload["draft"]
        assert payload["body"] == draft["body"]
        assert len(draft["assets"]) == 10
        self.tags[payload["tag_name"]] = payload["target_commitish"]
        self.create_tag(payload["tag_name"], payload["target_commitish"])
        draft.update(payload)
        self.published.append(release_id)
        return draft
