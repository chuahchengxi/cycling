//
//  ContentView.swift
//  cyclingskibidi
//
//  Created by cheng xi on 23/5/26.
//

import SwiftUI
import MapKit

struct ContentView: View {
    @State private var isSheetShown = true
    @State private var activeDetent: PresentationDetent = .fraction(0.2)
    var body: some View {
        VStack {
            HStack {
                Button {
                } label: {
                    Image(systemName: "arrowshape.turn.up.backward.fill")
                        .resizable()
                        .frame(width: 30, height: 30)
                }
                Text("ROUTE NAME GOES HERE")
                    .bold()
                    .font(.largeTitle)
                    .padding(.leading, 40)
            }
            Map()
                .sheet(isPresented: $isSheetShown){ SheetView(currentDetent: $activeDetent)
                    .presentationDetents([.fraction(0.2),.large], selection: $activeDetent)
                    .presentationBackgroundInteraction(.enabled)
                    .interactiveDismissDisabled()
            }
        }
    }
}
#Preview {
    ContentView()
}
