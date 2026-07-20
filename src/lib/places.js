// Loads the Google Maps JS "places" library once, lazily, on whichever page
// actually has an address input. See src/lib/address-autocomplete.js for the
// per-input wiring; pages should not call this directly.

const CALLBACK_NAME = "__solarsearchGoogleMapsLoaded";
let loadPromise = null;

export function loadGooglePlaces() {
  if (loadPromise) return loadPromise;

  const apiKey = import.meta.env.VITE_GOOGLE_MAPS_API_KEY;
  if (!apiKey) {
    console.warn("VITE_GOOGLE_MAPS_API_KEY not set — address autocomplete disabled.");
    return Promise.resolve(null);
  }

  if (window.google?.maps?.places) {
    loadPromise = Promise.resolve(window.google.maps.places);
    return loadPromise;
  }

  loadPromise = new Promise((resolve, reject) => {
    window[CALLBACK_NAME] = () => resolve(window.google.maps.places);
    const script = document.createElement("script");
    script.src = `https://maps.googleapis.com/maps/api/js?key=${encodeURIComponent(apiKey)}&libraries=places&loading=async&region=AU&callback=${CALLBACK_NAME}`;
    script.async = true;
    script.onerror = () => reject(new Error("Google Maps script failed to load"));
    document.head.appendChild(script);
  });

  return loadPromise;
}
