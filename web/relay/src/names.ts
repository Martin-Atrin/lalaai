const ADJ = [
  "cosmic", "sunny", "brave", "curious", "gentle", "lucky", "mellow", "nimble", "quiet", "rapid",
  "snappy", "witty", "zesty", "bold", "breezy", "clever", "dapper", "fuzzy", "jolly", "plucky",
  "shiny", "spicy", "swift", "tidy", "vivid", "wild", "cozy", "electric", "golden", "misty",
];
const NOUN = [
  "otter", "falcon", "panda", "lynx", "koala", "badger", "heron", "gecko", "walrus", "yak",
  "comet", "nebula", "pixel", "quasar", "maple", "cactus", "pebble", "harbor", "summit", "meadow",
  "octopus", "narwhal", "puffin", "raccoon", "tapir", "wombat", "orca", "moth", "bison", "fox",
];
const pick = <T>(a: T[]) => a[Math.floor(Math.random() * a.length)]!;
export const randomSlug = () => `${pick(ADJ)}-${pick(NOUN)}-${10 + Math.floor(Math.random() * 90)}`;
